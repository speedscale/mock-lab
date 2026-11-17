package lab;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** The Java version of the oracle lab's shop API, on the Oracle JDBC thin driver (ojdbc11). */
public final class Shop {
    private static final Pattern ID_ROUTE = Pattern.compile("^/(products|orders)/([^/]+)$");
    private static final Pattern JSON_INT = Pattern.compile("\"(\\w+)\"\\s*:\\s*(-?\\d+)");

    private final String url;
    private final Properties props;
    // a small pool of open connections, so prepared statements are reused across requests as an app pool does
    private final BlockingQueue<Connection> pool = new ArrayBlockingQueue<>(4);

    private Shop(String url, Properties props) {
        this.url = url;
        this.props = props;
    }

    static final class HttpError extends Exception {
        final int status;

        HttpError(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    record Reply(int status, Object body) {}

    private static String env(String name, String def) {
        String v = System.getenv(name);
        return v == null || v.isEmpty() ? def : v;
    }

    public static void main(String[] args) throws IOException {
        String url = "jdbc:oracle:thin:@//" + env("DB_HOST", "localhost") + ":" + env("DB_PORT", "11521")
                + "/" + env("DB_SERVICE", "FREEPDB1");
        Properties props = new Properties();
        props.setProperty("user", env("DB_USER", "shop"));
        props.setProperty("password", env("DB_PASSWORD", "LabShop2026"));
        Shop shop = new Shop(url, props);
        int port = Integer.parseInt(env("PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/", shop::handle);
        server.setExecutor(Executors.newFixedThreadPool(4));
        server.start();
        System.out.println("shop-java listening on :" + port + ", database "
                + env("DB_HOST", "localhost") + ":" + env("DB_PORT", "11521"));
    }

    private Connection take() throws SQLException {
        Connection c = pool.poll();
        if (c != null && !c.isClosed()) {
            return c;
        }
        return DriverManager.getConnection(url, props);
    }

    private void give(Connection c) {
        try {
            if (c.isClosed() || !c.getAutoCommit() || !pool.offer(c)) {
                c.close();
            }
        } catch (SQLException e) {
            // a broken connection is dropped
        }
    }

    private void handle(HttpExchange ex) throws IOException {
        Reply reply;
        try {
            reply = route(ex);
        } catch (HttpError e) {
            reply = new Reply(e.status, Map.of("error", e.getMessage()));
        } catch (SQLException e) {
            System.err.println(e);
            reply = new Reply(500, Map.of("error", "database: " + e.getMessage()));
        }
        byte[] body = Json.write(reply.body()).getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(reply.status(), body.length);
        ex.getResponseBody().write(body);
        ex.close();
    }

    private Reply route(HttpExchange ex) throws HttpError, SQLException, IOException {
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().getPath();
        Map<String, String> query = query(ex.getRequestURI().getRawQuery());
        if (method.equals("GET") && path.equals("/health")) {
            return health();
        }
        if (method.equals("GET") && path.equals("/products")) {
            return listProducts(query.getOrDefault("category", ""));
        }
        if (method.equals("POST") && path.equals("/orders")) {
            return placeOrder(ex.getRequestBody());
        }
        if (method.equals("GET") && path.equals("/reports/top-products")) {
            int limit;
            try {
                limit = positive(query.get("limit"));
            } catch (HttpError e) {
                limit = 3;
            }
            return topProducts(limit);
        }
        Matcher m = ID_ROUTE.matcher(path);
        if (method.equals("GET") && m.matches()) {
            int id = positive(m.group(2));
            return m.group(1).equals("products") ? getProduct(id) : getOrder(id);
        }
        throw new HttpError(404, "not found");
    }

    private Reply health() throws SQLException {
        Connection c = take();
        try (PreparedStatement st = c.prepareStatement("SELECT 1 FROM dual")) {
            st.executeQuery().close();
        } finally {
            give(c);
        }
        return new Reply(200, Map.of("status", "ok"));
    }

    private static Map<String, Object> product(ResultSet rs) throws SQLException {
        Map<String, Object> p = new LinkedHashMap<>();
        p.put("id", rs.getInt("id"));
        p.put("sku", rs.getString("sku"));
        p.put("name", rs.getString("name"));
        p.put("price_cents", rs.getInt("price_cents"));
        p.put("stock", rs.getInt("stock"));
        return p;
    }

    private Reply listProducts(String category) throws SQLException {
        Connection c = take();
        List<Object> products = new ArrayList<>();
        try (PreparedStatement st = c.prepareStatement(
                "SELECT id, sku, name, price_cents, stock FROM products WHERE category = ? ORDER BY id")) {
            st.setString(1, category);
            try (ResultSet rs = st.executeQuery()) {
                while (rs.next()) {
                    products.add(product(rs));
                }
            }
        } finally {
            give(c);
        }
        return new Reply(200, Map.of("products", products));
    }

    private Reply getProduct(int id) throws SQLException, HttpError {
        Connection c = take();
        try (PreparedStatement st = c.prepareStatement(
                "SELECT id, sku, name, price_cents, stock FROM products WHERE id = ?")) {
            st.setInt(1, id);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next()) {
                    throw new HttpError(404, "not found");
                }
                return new Reply(200, product(rs));
            }
        } finally {
            give(c);
        }
    }

    /** Takes the stock and records the order in one transaction, so two orders cannot sell the same unit. */
    private Reply placeOrder(InputStream in) throws SQLException, HttpError, IOException {
        Map<String, Integer> body = new LinkedHashMap<>();
        Matcher m = JSON_INT.matcher(new String(in.readAllBytes(), StandardCharsets.UTF_8));
        while (m.find()) {
            body.put(m.group(1), Integer.parseInt(m.group(2)));
        }
        int productId = positive(body.get("product_id"));
        int quantity = positive(body.get("quantity"));
        Connection c = take();
        try {
            c.setAutoCommit(false);
            int price;
            try (PreparedStatement st = c.prepareStatement(
                    "SELECT price_cents, stock FROM products WHERE id = ? FOR UPDATE")) {
                st.setInt(1, productId);
                try (ResultSet rs = st.executeQuery()) {
                    if (!rs.next()) {
                        throw new HttpError(404, "not found");
                    }
                    if (rs.getInt("stock") < quantity) {
                        throw new HttpError(409, "out of stock");
                    }
                    price = rs.getInt("price_cents");
                }
            }
            try (PreparedStatement st = c.prepareStatement(
                    "UPDATE products SET stock = stock - ? WHERE id = ?")) {
                st.setInt(1, quantity);
                st.setInt(2, productId);
                st.executeUpdate();
            }
            int total = price * quantity;
            int orderId;
            // naming the generated column makes the driver add RETURNING id INTO a bind to the statement it sends
            try (PreparedStatement st = c.prepareStatement(
                    "INSERT INTO orders (product_id, quantity, total_cents) VALUES (?, ?, ?)", new String[] {"id"})) {
                st.setInt(1, productId);
                st.setInt(2, quantity);
                st.setInt(3, total);
                st.executeUpdate();
                try (ResultSet rs = st.getGeneratedKeys()) {
                    rs.next();
                    orderId = rs.getInt(1);
                }
            }
            c.commit();
            Map<String, Object> o = new LinkedHashMap<>();
            o.put("id", orderId);
            o.put("product_id", productId);
            o.put("quantity", quantity);
            o.put("total_cents", total);
            return new Reply(201, o);
        } catch (SQLException | HttpError e) {
            c.rollback();
            throw e;
        } finally {
            c.setAutoCommit(true);
            give(c);
        }
    }

    private Reply getOrder(int id) throws SQLException, HttpError {
        Connection c = take();
        try (PreparedStatement st = c.prepareStatement(
                "SELECT o.id, o.product_id, p.name, o.quantity, o.total_cents FROM orders o "
                        + "JOIN products p ON p.id = o.product_id WHERE o.id = ?")) {
            st.setInt(1, id);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next()) {
                    throw new HttpError(404, "not found");
                }
                Map<String, Object> o = new LinkedHashMap<>();
                o.put("id", rs.getInt("id"));
                o.put("product_id", rs.getInt("product_id"));
                o.put("name", rs.getString("name"));
                o.put("quantity", rs.getInt("quantity"));
                o.put("total_cents", rs.getInt("total_cents"));
                return new Reply(200, o);
            }
        } finally {
            give(c);
        }
    }

    private Reply topProducts(int limit) throws SQLException {
        Connection c = take();
        List<Object> top = new ArrayList<>();
        int total;
        try (CallableStatement st = c.prepareCall("{call top_products(?, ?, ?)}")) {
            st.setInt(1, limit);
            st.registerOutParameter(2, Types.INTEGER);
            st.registerOutParameter(3, Types.REF_CURSOR);
            st.execute();
            total = st.getInt(2);
            try (ResultSet rs = st.getObject(3, ResultSet.class)) {
                while (rs.next()) {
                    Map<String, Object> s = new LinkedHashMap<>();
                    s.put("id", rs.getInt("id"));
                    s.put("name", rs.getString("name"));
                    s.put("sold", rs.getInt("sold"));
                    top.add(s);
                }
            }
        } finally {
            give(c);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("orders", total);
        out.put("top", top);
        return new Reply(200, out);
    }

    private static int positive(Object value) throws HttpError {
        try {
            int n = value instanceof Integer i ? i : Integer.parseInt(String.valueOf(value));
            if (n > 0) {
                return n;
            }
        } catch (NumberFormatException e) {
            // falls through to the error
        }
        throw new HttpError(400, "bad request");
    }

    private static Map<String, String> query(String raw) {
        Map<String, String> q = new LinkedHashMap<>();
        if (raw == null) {
            return q;
        }
        for (String pair : raw.split("&")) {
            String[] kv = pair.split("=", 2);
            q.put(URLDecoder.decode(kv[0], StandardCharsets.UTF_8),
                    kv.length > 1 ? URLDecoder.decode(kv[1], StandardCharsets.UTF_8) : "");
        }
        return q;
    }
}
