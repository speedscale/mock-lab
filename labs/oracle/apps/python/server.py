"""The Python version of the oracle lab's shop API, on python-oracledb in thin mode (the default)."""

import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import oracledb


def env(name, default):
    return os.environ.get(name) or default


class HTTPError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


pool = oracledb.create_pool(
    user=env("DB_USER", "shop"),
    password=env("DB_PASSWORD", "LabShop2026"),
    dsn=f"{env('DB_HOST', 'localhost')}:{env('DB_PORT', '11521')}/{env('DB_SERVICE', 'FREEPDB1')}",
    min=0,
    max=4,
    increment=1,
)


def positive(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise HTTPError(400, "bad request")
    if n <= 0 or isinstance(value, bool):
        raise HTTPError(400, "bad request")
    return n


def product(r):
    return {"id": r[0], "sku": r[1], "name": r[2], "price_cents": r[3], "stock": r[4]}


def health(_):
    with pool.acquire() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1 FROM dual")
        cur.fetchall()
    return 200, {"status": "ok"}


def list_products(query):
    category = query.get("category", [""])[0]
    with pool.acquire() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, sku, name, price_cents, stock FROM products WHERE category = :category ORDER BY id",
            category=category,
        )
        return 200, {"products": [product(r) for r in cur.fetchall()]}


def get_product(product_id):
    with pool.acquire() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, sku, name, price_cents, stock FROM products WHERE id = :id", id=product_id)
        row = cur.fetchone()
    if row is None:
        raise HTTPError(404, "not found")
    return 200, product(row)


def place_order(body):
    """Takes the stock and records the order in one transaction, so two orders cannot sell the same unit."""
    try:
        data = json.loads(body or b"null")
    except ValueError:
        raise HTTPError(400, "bad request")
    if not isinstance(data, dict):
        raise HTTPError(400, "bad request")
    product_id = positive(data.get("product_id"))
    quantity = positive(data.get("quantity"))
    with pool.acquire() as conn, conn.cursor() as cur:
        try:
            cur.execute("SELECT price_cents, stock FROM products WHERE id = :id FOR UPDATE", id=product_id)
            row = cur.fetchone()
            if row is None:
                raise HTTPError(404, "not found")
            price, stock = row
            if stock < quantity:
                raise HTTPError(409, "out of stock")
            cur.execute("UPDATE products SET stock = stock - :quantity WHERE id = :id", quantity=quantity, id=product_id)
            total = price * quantity
            order_id = cur.var(int)
            cur.execute(
                "INSERT INTO orders (product_id, quantity, total_cents) VALUES (:product_id, :quantity, :total) "
                "RETURNING id INTO :order_id",
                product_id=product_id,
                quantity=quantity,
                total=total,
                order_id=order_id,
            )
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return 201, {"id": order_id.getvalue()[0], "product_id": product_id, "quantity": quantity, "total_cents": total}


def get_order(order_id):
    with pool.acquire() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT o.id, o.product_id, p.name, o.quantity, o.total_cents FROM orders o "
            "JOIN products p ON p.id = o.product_id WHERE o.id = :id",
            id=order_id,
        )
        r = cur.fetchone()
    if r is None:
        raise HTTPError(404, "not found")
    return 200, {"id": r[0], "product_id": r[1], "name": r[2], "quantity": r[3], "total_cents": r[4]}


def top_products(query):
    try:
        limit = positive(query.get("limit", ["3"])[0])
    except HTTPError:
        limit = 3
    # the procedure returns its rows as a REF CURSOR OUT parameter, which python-oracledb hands back as a cursor
    with pool.acquire() as conn, conn.cursor() as cur, conn.cursor() as top_cursor:
        total = cur.var(int)
        cur.callproc("top_products", [limit, total, top_cursor])
        top = [{"id": r[0], "name": r[1], "sold": int(r[2])} for r in top_cursor.fetchall()]
    return 200, {"orders": total.getvalue(), "top": top}


ID_ROUTE = re.compile(r"^/(products|orders)/([^/]+)$")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def dispatch(self, method):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        try:
            status, body = self.route(method, url.path, query)
        except HTTPError as err:
            status, body = err.status, {"error": str(err)}
        except Exception as err:  # noqa: BLE001 - the API reports any database error as a 500
            self.log_error("%s", err)
            status, body = 500, {"error": f"database: {err}"}
        payload = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def route(self, method, path, query):
        if method == "GET" and path == "/health":
            return health(query)
        if method == "GET" and path == "/products":
            return list_products(query)
        if method == "POST" and path == "/orders":
            length = int(self.headers.get("Content-Length") or 0)
            return place_order(self.rfile.read(length))
        if method == "GET" and path == "/reports/top-products":
            return top_products(query)
        m = ID_ROUTE.match(path)
        if method == "GET" and m:
            target = get_product if m.group(1) == "products" else get_order
            return target(positive(m.group(2)))
        raise HTTPError(404, "not found")


if __name__ == "__main__":
    port = int(env("PORT", "8080"))
    print(f"shop-python listening on :{port}, database {env('DB_HOST', 'localhost')}:{env('DB_PORT', '11521')}",
          flush=True)
    ThreadingHTTPServer(("", port), Handler).serve_forever()
