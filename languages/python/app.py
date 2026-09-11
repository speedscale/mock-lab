#!/usr/bin/env python3
"""proxymock CNCF demo app (Python).

Exposes a small HTTP API on :8080 and fulfills each request by calling the CNCF
downstream API. urllib honors HTTP(S)_PROXY, so proxymock can record, mock, and
replay the downstream calls with no code change.
"""
import json
import os
import secrets
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

DOWNSTREAM = os.environ.get("DOWNSTREAM_URL", "https://demo-api.trafficreplay.com")
PORT = int(os.environ.get("PORT", "8080"))

# In-memory state for the OAuth/orders endpoints (moving IDs are generated per call).
VALID_TOKENS = set()
ORDERS = {}


def fetch(path):
    with urllib.request.urlopen(DOWNSTREAM + path, timeout=10) as r:
        return r.status, r.read()


def project_exists(project):
    try:
        status, _ = fetch("/v1/project/" + project)
        return status == 200
    except Exception:  # noqa: BLE001 - treat any downstream failure as not found
        return False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())

    def _authed(self):
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and auth[len("Bearer "):] in VALID_TOKENS

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        p = self.path
        try:
            if p == "/":
                self._send(200, {"service": "proxymock-cncf-demo", "lang": "python", "downstream": DOWNSTREAM})
            elif p == "/api/projects":
                self._send(*fetch("/v1/projects"))
            elif p.startswith("/api/projects/"):
                self._send(*fetch("/v1/project/" + p.split("/api/projects/", 1)[1]))
            elif p == "/api/categories":
                # Report the per-category counts with their total, so callers do not
                # have to add them up themselves.
                _, raw = fetch("/v1/categories")
                try:
                    categories = json.loads(raw)["categories"]
                except (KeyError, TypeError, ValueError):
                    self._send(500, {"error": "cannot read category list"})
                    return
                self._send(200, {"categories": categories, "total": sum(c["count"] for c in categories)})
            elif p == "/api/stats":
                _, body = fetch("/v1/projects")
                projects = json.loads(body)
                by_maturity = {}
                for proj in projects:
                    by_maturity[proj["maturity"]] = by_maturity.get(proj["maturity"], 0) + 1
                self._send(200, {"total": len(projects), "by_maturity": by_maturity})
            elif p.startswith("/api/orders/"):
                if not self._authed():
                    self._send(401, {"error": "missing or invalid bearer token"})
                    return
                order_id = p.split("/api/orders/", 1)[1]
                order = ORDERS.get(order_id)
                if order is None:
                    self._send(404, {"error": "order not found", "order_id": order_id})
                else:
                    self._send(200, order)
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001 - demo app, surface the error
            self._send(502, {"error": str(e)})

    def do_POST(self):
        p = self.path
        try:
            if p == "/oauth/token":
                token = secrets.token_hex(32)
                VALID_TOKENS.add(token)
                self._send(200, {"access_token": token, "token_type": "Bearer", "expires_in": 3600})
            elif p == "/api/orders":
                if not self._authed():
                    self._send(401, {"error": "missing or invalid bearer token"})
                    return
                body = self._read_body()
                req = json.loads(body) if body else {}
                project = req.get("project", "")
                if not project:
                    self._send(400, {"error": "project is required"})
                    return
                if not project_exists(project):
                    self._send(404, {"error": "unknown project", "project": project})
                    return
                order = {
                    "order_id": "order-" + secrets.token_hex(8),
                    "project": project,
                    "status": "created",
                    "created": datetime.now(timezone.utc).isoformat(),
                }
                ORDERS[order["order_id"]] = order
                self._send(201, order)
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001 - demo app, surface the error
            self._send(502, {"error": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"python demo on :{PORT} (downstream={DOWNSTREAM})")
    HTTPServer(("", PORT), Handler).serve_forever()
