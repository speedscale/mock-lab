package lab;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.SQLRecoverableException;
import java.sql.SQLTimeoutException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.core.env.Environment;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** The shop API uses Oracle JDBC Thin to run orders and reports. */
@RestController
public final class Shop {
    private static final Pattern JSON_INT = Pattern.compile("\"(\\w+)\"\\s*:\\s*(-?\\d+)");

    private final String url;
    private final Properties props;
    // a small pool of open connections, so prepared statements are reused across requests as an app pool does
    private final BlockingQueue<Connection> pool = new ArrayBlockingQueue<>(4);

    public Shop(Environment env) {
        this.url = "jdbc:oracle:thin:@//" + env.getProperty("DB_HOST", "localhost") + ":"
                + env.getProperty("DB_PORT", "11521") + "/" + env.getProperty("DB_SERVICE", "FREEPDB1");
        this.props = new Properties();
        props.setProperty("user", env.getProperty("DB_USER", "shop"));
        props.setProperty("password", env.getProperty("DB_PASSWORD", "LabShop2026"));
        props.setProperty("oracle.net.CONNECT_TIMEOUT", "2000ms");
        props.setProperty("oracle.jdbc.ReadTimeout", env.getProperty("DB_READ_TIMEOUT_MS", "2000"));
    }

    static final class HttpError extends Exception {
        final int status;

        HttpError(int status, String message) {
            super(message);
            this.status = status;
        }
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

    private static ResponseEntity<String> reply(int status, Object body) {
        return ResponseEntity.status(status).contentType(MediaType.APPLICATION_JSON).body(Json.write(body));
    }

    @ExceptionHandler(HttpError.class)
    public ResponseEntity<String> handleHttpError(HttpError error) {
        return reply(error.status, Map.of("error", error.getMessage()));
    }

    @ExceptionHandler(SQLException.class)
    public ResponseEntity<String> handleDatabaseError(SQLException error) {
        System.err.println(error);
        if (error instanceof SQLRecoverableException || error instanceof SQLTimeoutException) {
            return reply(503, Map.of("error", "database unavailable"));
        }
        return reply(500, Map.of("error", "database: " + error.getMessage()));
    }

    @GetMapping("/health")
    public ResponseEntity<String> health() throws SQLException {
        Connection c = take();
        try (PreparedStatement st = c.prepareStatement("SELECT 1 FROM dual")) {
            st.executeQuery().close();
        } finally {
            give(c);
        }
        return reply(200, Map.of("status", "ok"));
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

    @GetMapping("/products")
    public ResponseEntity<String> listProducts(@RequestParam(name = "category", defaultValue = "") String category)
            throws SQLException {
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
        return reply(200, Map.of("products", products));
    }

    @GetMapping("/products/{id}")
    public ResponseEntity<String> getProduct(@PathVariable("id") String productId) throws SQLException, HttpError {
        int id = positive(productId);
        Connection c = take();
        try (PreparedStatement st = c.prepareStatement(
                "SELECT id, sku, name, price_cents, stock FROM products WHERE id = ?")) {
            st.setInt(1, id);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next()) {
                    throw new HttpError(404, "not found");
                }
                return reply(200, product(rs));
            }
        } finally {
            give(c);
        }
    }

    /** Takes the stock and records the order in one transaction, so two orders cannot sell the same unit. */
    @PostMapping("/orders")
    public ResponseEntity<String> placeOrder(InputStream in) throws SQLException, HttpError, IOException {
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
            return reply(201, o);
        } catch (SQLException | HttpError e) {
            c.rollback();
            throw e;
        } finally {
            c.setAutoCommit(true);
            give(c);
        }
    }

    @GetMapping("/orders/{id}")
    public ResponseEntity<String> getOrder(@PathVariable("id") String orderId) throws SQLException, HttpError {
        int id = positive(orderId);
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
                return reply(200, o);
            }
        } finally {
            give(c);
        }
    }

    @GetMapping("/reports/top-products")
    public ResponseEntity<String> topProducts(@RequestParam(name = "limit", required = false) String requestedLimit)
            throws SQLException {
        int limit;
        try {
            limit = positive(requestedLimit);
        } catch (HttpError e) {
            limit = 3;
        }
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
        return reply(200, out);
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

}
