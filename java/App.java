// proxymock CNCF demo app (Java, single-file). Run with: java App.java
//
// Exposes a small HTTP API on :8080 and fulfills each request by calling the CNCF
// downstream API. java.net.http.HttpClient honors the JVM proxy flags
// (-Dhttp.proxyHost / -Dhttp.proxyPort), so proxymock can record/mock/replay.
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public class App {
    static final String DOWNSTREAM =
            System.getenv().getOrDefault("DOWNSTREAM_URL", "https://demo-api-dev.trafficreplay.com");
    static final HttpClient CLIENT = HttpClient.newHttpClient();

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
}
