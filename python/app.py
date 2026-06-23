#!/usr/bin/env python3
"""proxymock CNCF demo app (Python).

Exposes a small HTTP API on :8080 and fulfills each request by calling the CNCF
downstream API. urllib honors HTTP(S)_PROXY, so proxymock can record, mock, and
replay the downstream calls with no code change.
"""
import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

DOWNSTREAM = os.environ.get("DOWNSTREAM_URL", "https://demo-api.trafficreplay.com")
PORT = int(os.environ.get("PORT", "8080"))


def fetch(path):
    with urllib.request.urlopen(DOWNSTREAM + path, timeout=10) as r:
        return r.status, r.read()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())

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
                self._send(*fetch("/v1/categories"))
            elif p == "/api/stats":
                _, body = fetch("/v1/projects")
                projects = json.loads(body)
                by_maturity = {}
                for proj in projects:
                    by_maturity[proj["maturity"]] = by_maturity.get(proj["maturity"], 0) + 1
                self._send(200, {"total": len(projects), "by_maturity": by_maturity})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001 - demo app, surface the error
            self._send(502, {"error": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"python demo on :{PORT} (downstream={DOWNSTREAM})")
    HTTPServer(("", PORT), Handler).serve_forever()
