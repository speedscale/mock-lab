"""The Python version of the sqlserver lab's shop API, on pymssql (FreeTDS)."""

import contextlib
import json
import os
import queue
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import pymssql


def env(name, default):
    return os.environ.get(name) or default


class HTTPError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


_pool = queue.LifoQueue(maxsize=4)


def _connect():
    return pymssql.connect(
        server=env("DB_HOST", "localhost"),
        port=env("DB_PORT", "11433"),
        user=env("DB_USER", "app"),
        password=env("DB_PASSWORD", "Lab-App-2026!"),
        database=env("DB_NAME", "shop"),
        encryption="require",
        appname="shop-python",
        as_dict=True,
        autocommit=True,
    )


@contextlib.contextmanager
def connection():
    """Lends a pooled connection, so requests reuse sessions as the other apps' pools do."""
    try:
        conn = _pool.get_nowait()
    except queue.Empty:
        conn = _connect()
    try:
        yield conn
    except pymssql.OperationalError:
        conn.close()
        raise
    else:
        try:
            _pool.put_nowait(conn)
        except queue.Full:
            conn.close()


def positive(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise HTTPError(400, "bad request")
    if n <= 0 or isinstance(value, bool):
        raise HTTPError(400, "bad request")
    return n


def product(r):
    return {"id": r["id"], "sku": r["sku"], "name": r["name"], "price_cents": r["price_cents"], "stock": r["stock"]}


def health(_):
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1 AS one")
        cur.fetchall()
    return 200, {"status": "ok"}


def list_products(query):
    category = query.get("category", [""])[0]
    with connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, sku, name, price_cents, stock FROM dbo.products WHERE category = %s ORDER BY id", (category,)
        )
        return 200, {"products": [product(r) for r in cur.fetchall()]}


def get_product(product_id):
    with connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, sku, name, price_cents, stock FROM dbo.products WHERE id = %d", (product_id,))
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
    with connection() as conn, conn.cursor() as cur:
        cur.execute("BEGIN TRANSACTION")
        try:
            cur.execute("SELECT price_cents, stock FROM dbo.products WITH (UPDLOCK) WHERE id = %d", (product_id,))
            row = cur.fetchone()
            if row is None:
                raise HTTPError(404, "not found")
            if row["stock"] < quantity:
                raise HTTPError(409, "out of stock")
            cur.execute("UPDATE dbo.products SET stock = stock - %d WHERE id = %d", (quantity, product_id))
            total = row["price_cents"] * quantity
            cur.execute(
                "INSERT INTO dbo.orders (product_id, quantity, total_cents) OUTPUT INSERTED.id VALUES (%d, %d, %d)",
                (product_id, quantity, total),
            )
            order_id = cur.fetchone()["id"]
            cur.execute("COMMIT TRANSACTION")
        except Exception:
            cur.execute("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION")
            raise
    return 201, {"id": order_id, "product_id": product_id, "quantity": quantity, "total_cents": total}


def get_order(order_id):
    with connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT o.id, o.product_id, p.name, o.quantity, o.total_cents FROM dbo.orders o "
            "JOIN dbo.products p ON p.id = o.product_id WHERE o.id = %d",
            (order_id,),
        )
        r = cur.fetchone()
    if r is None:
        raise HTTPError(404, "not found")
    return 200, {"id": r["id"], "product_id": r["product_id"], "name": r["name"], "quantity": r["quantity"],
                 "total_cents": r["total_cents"]}


def top_products(query):
    try:
        limit = positive(query.get("limit", ["3"])[0])
    except HTTPError:
        limit = 3
    # pymssql does not return an OUTPUT parameter from callproc when the procedure also returns rows, so the call
    # runs as a batch that selects the output parameter after the rows
    with connection() as conn, conn.cursor() as cur:
        cur.execute(
            "DECLARE @total int; EXEC dbo.top_products @limit = %d, @total = @total OUTPUT; SELECT @total AS total",
            (limit,),
        )
        top = [{"id": r["id"], "name": r["name"], "sold": r["sold"]} for r in cur.fetchall()]
        cur.nextset()
        total = cur.fetchone()["total"]
    return 200, {"orders": total, "top": top}


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
    print(f"shop-python listening on :{port}, database {env('DB_HOST', 'localhost')}:{env('DB_PORT', '11433')}",
          flush=True)
    ThreadingHTTPServer(("", port), Handler).serve_forever()
