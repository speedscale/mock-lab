// proxymock CNCF demo app (.NET). Exposes a small HTTP API on :8080 and fulfills each
// request by calling the CNCF downstream API. HttpClient honors HTTP(S)_PROXY env vars,
// so proxymock can record/mock/replay the downstream calls. Run with: dotnet run
using System.Text.Json;

var downstream = Environment.GetEnvironmentVariable("DOWNSTREAM_URL") ?? "https://demo-api.trafficreplay.com";
var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
var http = new HttpClient();

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
app.MapGet("/api/categories", () => Proxy("/v1/categories"));
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

Console.WriteLine($"dotnet demo on :{port} (downstream={downstream})");
app.Run();
