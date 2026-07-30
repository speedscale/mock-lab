// proxymock CNCF demo app (.NET). Exposes a small HTTP API on :8080 and fulfills each
// request by calling the CNCF downstream API. HttpClient honors HTTP(S)_PROXY env vars,
// so proxymock can record/mock/replay the downstream calls. Run with: dotnet run
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;

var downstream = Environment.GetEnvironmentVariable("DOWNSTREAM_URL") ?? "https://demo-api.trafficreplay.com";
var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
var http = new HttpClient();
var jsonOpts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
var app = builder.Build();

async Task<IResult> Proxy(string path)
{
    var r = await http.GetAsync(downstream + path);
    var text = await r.Content.ReadAsStringAsync();
    return Results.Content(text, "application/json", null, (int)r.StatusCode);
}

app.MapGet("/", () => Results.Json(new { service = "proxymock-cncf-demo", lang = "dotnet", downstream }));
app.MapGet("/api/projects", () => Proxy("/v1/projects"));
app.MapGet("/api/projects/{id}", (string id) => Proxy("/v1/project/" + id));
app.MapGet("/api/categories", async () =>
{
    // Report the per-category counts with their total, so callers do not have to
    // add them up themselves.
    var raw = await http.GetStringAsync(downstream + "/v1/categories");
    CategoryPage? page;
    try
    {
        page = JsonSerializer.Deserialize<CategoryPage>(raw, jsonOpts);
    }
    catch (JsonException)
    {
        return Results.Json(new { error = "cannot read category list" }, statusCode: 500);
    }
    var categories = page?.Categories ?? new List<Category>();
    return Results.Json(new { categories, total = categories.Sum(c => c.Count) });
});
app.MapGet("/api/stats", async () =>
{
    var projects = await http.GetFromJsonAsync<List<JsonElement>>(downstream + "/v1/projects") ?? new();
    var byMaturity = new Dictionary<string, int>();
    foreach (var p in projects)
    {
        var m = p.GetProperty("maturity").GetString() ?? "Unknown";
        byMaturity[m] = byMaturity.GetValueOrDefault(m) + 1;
    }
    return Results.Json(new { total = projects.Count, by_maturity = byMaturity });
});

// --- OAuth + orders (in-memory, fresh tokens/ids per call by design) ---
var tokens = new ConcurrentDictionary<string, byte>();
var orders = new ConcurrentDictionary<string, object>();

string Hex(int bytes) => Convert.ToHexString(RandomNumberGenerator.GetBytes(bytes)).ToLowerInvariant();

bool HasValidToken(HttpRequest req)
{
    var auth = req.Headers.Authorization.ToString();
    const string prefix = "Bearer ";
    if (!auth.StartsWith(prefix, StringComparison.Ordinal)) return false;
    var tok = auth.Substring(prefix.Length);
    return tok.Length > 0 && tokens.ContainsKey(tok);
}

app.MapPost("/oauth/token", () =>
{
    var token = Hex(32);
    tokens[token] = 1;
    return Results.Json(new { access_token = token, token_type = "Bearer", expires_in = 3600 });
});

app.MapPost("/api/orders", async (HttpRequest req) =>
{
    if (!HasValidToken(req))
        return Results.Json(new { error = "missing or invalid bearer token" }, statusCode: 401);

    string? project = null;
    try
    {
        // Read the raw body and parse it ourselves so we don't depend on the
        // Content-Type header (matches the other languages' lenient parsing).
        using var reader = new StreamReader(req.Body);
        var raw = await reader.ReadToEndAsync();
        using var doc = JsonDocument.Parse(raw);
        if (doc.RootElement.ValueKind == JsonValueKind.Object
            && doc.RootElement.TryGetProperty("project", out var p)
            && p.ValueKind == JsonValueKind.String)
            project = p.GetString();
    }
    catch { /* malformed/empty body -> treated as missing project */ }

    if (string.IsNullOrEmpty(project))
        return Results.Json(new { error = "project is required" }, statusCode: 400);

    var check = await http.GetAsync(downstream + "/v1/project/" + project);
    if ((int)check.StatusCode != 200)
        return Results.Json(new { error = "unknown project", project }, statusCode: 404);

    var orderId = "order-" + Hex(8);
    var order = new { order_id = orderId, project, status = "created", created = DateTime.UtcNow.ToString("o") };
    orders[orderId] = order;
    return Results.Json(order, statusCode: 201);
});

app.MapGet("/api/orders/{id}", (string id, HttpRequest req) =>
{
    if (!HasValidToken(req))
        return Results.Json(new { error = "missing or invalid bearer token" }, statusCode: 401);
    if (!orders.TryGetValue(id, out var order))
        return Results.Json(new { error = "order not found", order_id = id }, statusCode: 404);
    return Results.Json(order);
});

Console.WriteLine($"dotnet demo on :{port} (downstream={downstream})");
app.Run();

record Category(string Name, int Count);
record CategoryPage(List<Category> Categories);
