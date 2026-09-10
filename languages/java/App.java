// proxymock CNCF demo app (Java, single-file). Run with: java App.java
//
// Exposes a small HTTP API on :8080 and fulfills each request by calling the CNCF
// downstream API. java.net.http.HttpClient honors the JVM proxy flags
// (-Dhttp.proxyHost / -Dhttp.proxyPort), so proxymock can record/mock/replay.
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class App {
    static final String DOWNSTREAM =
            System.getenv().getOrDefault("DOWNSTREAM_URL", "https://demo-api.trafficreplay.com");
    static final HttpClient CLIENT = HttpClient.newHttpClient();

    // In-memory OAuth/order state. No external store; resets when the process exits.
    static final Set<String> TOKENS = Collections.synchronizedSet(new HashSet<>());
    static final Map<String, String> ORDERS = Collections.synchronizedMap(new HashMap<>());
    static final SecureRandom RNG = new SecureRandom();
    static final Pattern PROJECT_FIELD =
            Pattern.compile("\"project\"\\s*:\\s*\"([^\"]*)\"");

    static void send(HttpExchange ex, int code, String body) throws IOException {
        byte[] b = body.getBytes();
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(code, b.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(b);
        }
    }

    static void proxy(HttpExchange ex, String path) throws Exception {
        HttpResponse<String> r = CLIENT.send(
                HttpRequest.newBuilder(URI.create(DOWNSTREAM + path)).build(),
                HttpResponse.BodyHandlers.ofString());
        send(ex, r.statusCode(), r.body());
    }

    public static void main(String[] args) throws IOException {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/", ex -> {
            String p = ex.getRequestURI().getPath();
            String m = ex.getRequestMethod();
            try {
                if (p.equals("/")) {
                    send(ex, 200, "{\"service\":\"proxymock-cncf-demo\",\"lang\":\"java\",\"downstream\":\"" + DOWNSTREAM + "\"}");
                } else if (p.equals("/api/projects")) {
                    proxy(ex, "/v1/projects");
                } else if (p.startsWith("/api/projects/")) {
                    proxy(ex, "/v1/project/" + p.substring("/api/projects/".length()));
                } else if (p.equals("/api/categories")) {
                    proxy(ex, "/v1/categories");
                } else if (p.equals("/api/stats")) {
                    stats(ex);
                } else if (p.equals("/oauth/token") && m.equals("POST")) {
                    oauthToken(ex);
                } else if (p.equals("/api/orders") && m.equals("POST")) {
                    createOrder(ex);
                } else if (p.startsWith("/api/orders/") && m.equals("GET")) {
                    getOrder(ex, p.substring("/api/orders/".length()));
                } else {
                    send(ex, 404, "{\"error\":\"not found\"}");
                }
            } catch (Exception e) {
                try {
                    send(ex, 502, "{\"error\":\"" + e.getMessage() + "\"}");
                } catch (IOException ignored) {
                }
            }
        });
        server.start();
        System.out.println("java demo on :" + port + " (downstream=" + DOWNSTREAM + ")");
    }

    // stats aggregates maturity counts. Java has no built-in JSON parser, so this counts
    // the (distinct) maturity value strings in the raw response — dependency-free.
    static void stats(HttpExchange ex) throws Exception {
        HttpResponse<String> r = CLIENT.send(
                HttpRequest.newBuilder(URI.create(DOWNSTREAM + "/v1/projects")).build(),
                HttpResponse.BodyHandlers.ofString());
        String b = r.body();
        int total = count(b, "\"id\":");
        int grad = count(b, "\"Graduated\"");
        int inc = count(b, "\"Incubating\"");
        int sand = count(b, "\"Sandbox\"");
        send(ex, 200, "{\"total\":" + total + ",\"by_maturity\":{\"Graduated\":" + grad
                + ",\"Incubating\":" + inc + ",\"Sandbox\":" + sand + "}}");
    }

    static int count(String s, String sub) {
        int n = 0, i = 0;
        while ((i = s.indexOf(sub, i)) != -1) {
            n++;
            i += sub.length();
        }
        return n;
    }

    // oauthToken mints an opaque bearer token and records it as valid.
    static void oauthToken(HttpExchange ex) throws IOException {
        String token = hex(32);
        TOKENS.add(token);
        send(ex, 200, "{\"access_token\":\"" + token + "\",\"token_type\":\"Bearer\",\"expires_in\":3600}");
    }

    // createOrder validates the project against the downstream then stores an order.
    static void createOrder(HttpExchange ex) throws Exception {
        if (!authorized(ex)) {
            send(ex, 401, "{\"error\":\"missing or invalid bearer token\"}");
            return;
        }
        String body = readBody(ex);
        String project = extractProject(body);
        if (project == null || project.isEmpty()) {
            send(ex, 400, "{\"error\":\"project is required\"}");
            return;
        }
        HttpResponse<String> r = CLIENT.send(
                HttpRequest.newBuilder(URI.create(DOWNSTREAM + "/v1/project/" + project)).build(),
                HttpResponse.BodyHandlers.ofString());
        if (r.statusCode() != 200) {
            send(ex, 404, "{\"error\":\"unknown project\",\"project\":\"" + project + "\"}");
            return;
        }
        String orderId = "order-" + hex(8);
        String order = "{\"order_id\":\"" + orderId + "\",\"project\":\"" + project
                + "\",\"status\":\"created\",\"created\":\"" + Instant.now().toString() + "\"}";
        ORDERS.put(orderId, order);
        send(ex, 201, order);
    }

    // getOrder returns a previously stored order by id.
    static void getOrder(HttpExchange ex, String id) throws IOException {
        if (!authorized(ex)) {
            send(ex, 401, "{\"error\":\"missing or invalid bearer token\"}");
            return;
        }
        String order = ORDERS.get(id);
        if (order == null) {
            send(ex, 404, "{\"error\":\"order not found\",\"order_id\":\"" + id + "\"}");
            return;
        }
        send(ex, 200, order);
    }

    static boolean authorized(HttpExchange ex) {
        String auth = ex.getRequestHeaders().getFirst("Authorization");
        if (auth == null || !auth.startsWith("Bearer ")) {
            return false;
        }
        return TOKENS.contains(auth.substring("Bearer ".length()));
    }

    static String readBody(HttpExchange ex) throws IOException {
        try (InputStream is = ex.getRequestBody()) {
            return new String(is.readAllBytes());
        }
    }

    // extractProject pulls "project" out of {"project":"X"} without a JSON parser.
    static String extractProject(String body) {
        if (body == null) {
            return null;
        }
        Matcher mm = PROJECT_FIELD.matcher(body);
        return mm.find() ? mm.group(1) : null;
    }

    static String hex(int nBytes) {
        byte[] b = new byte[nBytes];
        RNG.nextBytes(b);
        StringBuilder sb = new StringBuilder(nBytes * 2);
        for (byte x : b) {
            sb.append(Character.forDigit((x >> 4) & 0xF, 16));
            sb.append(Character.forDigit(x & 0xF, 16));
        }
        return sb.toString();
    }
}
