// proxymock CNCF demo app (Kotlin, single-file).
// Run: kotlinc App.kt -include-runtime -d app.jar && java -jar app.jar
//
// Same JVM HTTP stack as languages/java — com.sun.net.httpserver +
// java.net.http.HttpClient — so proxymock uses the same SOCKS proxy and JKS
// truststore flags. Kotlin is not a different capture path; see kotlin/README.md.
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.security.SecureRandom
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

val DOWNSTREAM = System.getenv("DOWNSTREAM_URL") ?: "https://demo-api.trafficreplay.com"
val CLIENT: HttpClient = HttpClient.newHttpClient()
val TOKENS: MutableSet<String> = ConcurrentHashMap.newKeySet()
val ORDERS = ConcurrentHashMap<String, String>()
val RNG = SecureRandom()
val PROJECT_FIELD = Regex("\"project\"\\s*:\\s*\"([^\"]*)\"")

fun send(ex: HttpExchange, code: Int, body: String) {
    val b = body.toByteArray()
    ex.responseHeaders.set("Content-Type", "application/json")
    ex.sendResponseHeaders(code, b.size.toLong())
    ex.responseBody.use { it.write(b) }
}

fun proxy(ex: HttpExchange, path: String) {
    val r = CLIENT.send(
        HttpRequest.newBuilder(URI.create(DOWNSTREAM + path)).build(),
        HttpResponse.BodyHandlers.ofString(),
    )
    send(ex, r.statusCode(), r.body())
}

fun hex(nBytes: Int): String {
    val b = ByteArray(nBytes)
    RNG.nextBytes(b)
    return b.joinToString("") { "%02x".format(it) }
}

fun count(s: String, sub: String): Int {
    var n = 0
    var i = 0
    while (true) {
        val j = s.indexOf(sub, i)
        if (j < 0) return n
        n++
        i = j + sub.length
    }
}

fun authorized(ex: HttpExchange): Boolean {
    val auth = ex.requestHeaders.getFirst("Authorization") ?: return false
    if (!auth.startsWith("Bearer ")) return false
    return TOKENS.contains(auth.removePrefix("Bearer "))
}

fun readBody(ex: HttpExchange): String =
    ex.requestBody.use { it.readAllBytes().toString(Charsets.UTF_8) }

fun extractProject(body: String?): String? {
    if (body == null) return null
    return PROJECT_FIELD.find(body)?.groupValues?.get(1)
}

fun main() {
    val port = System.getenv("PORT")?.toIntOrNull() ?: 8080
    val server = HttpServer.create(InetSocketAddress(port), 0)
    server.createContext("/") { ex ->
        val p = ex.requestURI.path
        val m = ex.requestMethod
        try {
            when {
                p == "/" ->
                    send(ex, 200, """{"service":"proxymock-cncf-demo","lang":"kotlin","downstream":"$DOWNSTREAM"}""")
                p == "/api/projects" -> proxy(ex, "/v1/projects")
                p.startsWith("/api/projects/") ->
                    proxy(ex, "/v1/project/" + p.removePrefix("/api/projects/"))
                p == "/api/categories" -> proxy(ex, "/v1/categories")
                p == "/api/stats" -> {
                    val r = CLIENT.send(
                        HttpRequest.newBuilder(URI.create("$DOWNSTREAM/v1/projects")).build(),
                        HttpResponse.BodyHandlers.ofString(),
                    )
                    val b = r.body()
                    val total = count(b, "\"id\":")
                    val grad = count(b, "\"Graduated\"")
                    val inc = count(b, "\"Incubating\"")
                    val sand = count(b, "\"Sandbox\"")
                    send(
                        ex,
                        200,
                        """{"total":$total,"by_maturity":{"Graduated":$grad,"Incubating":$inc,"Sandbox":$sand}}""",
                    )
                }
                p == "/oauth/token" && m == "POST" -> {
                    val token = hex(32)
                    TOKENS.add(token)
                    send(ex, 200, """{"access_token":"$token","token_type":"Bearer","expires_in":3600}""")
                }
                p == "/api/orders" && m == "POST" -> {
                    if (!authorized(ex)) {
                        send(ex, 401, """{"error":"missing or invalid bearer token"}""")
                    } else {
                        val project = extractProject(readBody(ex)).orEmpty()
                        if (project.isEmpty()) {
                            send(ex, 400, """{"error":"project is required"}""")
                        } else {
                            val r = CLIENT.send(
                                HttpRequest.newBuilder(URI.create("$DOWNSTREAM/v1/project/$project")).build(),
                                HttpResponse.BodyHandlers.ofString(),
                            )
                            if (r.statusCode() != 200) {
                                send(ex, 404, """{"error":"unknown project","project":"$project"}""")
                            } else {
                                val orderId = "order-" + hex(8)
                                val order =
                                    """{"order_id":"$orderId","project":"$project","status":"created","created":"${Instant.now()}"}"""
                                ORDERS[orderId] = order
                                send(ex, 201, order)
                            }
                        }
                    }
                }
                p.startsWith("/api/orders/") && m == "GET" -> {
                    if (!authorized(ex)) {
                        send(ex, 401, """{"error":"missing or invalid bearer token"}""")
                    } else {
                        val id = p.removePrefix("/api/orders/")
                        val order = ORDERS[id]
                        if (order == null) {
                            send(ex, 404, """{"error":"order not found","order_id":"$id"}""")
                        } else {
                            send(ex, 200, order)
                        }
                    }
                }
                else -> send(ex, 404, """{"error":"not found"}""")
            }
        } catch (e: Exception) {
            try {
                send(ex, 502, """{"error":"${e.message}"}""")
            } catch (_: Exception) {
            }
        }
    }
    server.start()
    println("kotlin demo on :$port (downstream=$DOWNSTREAM)")
}
