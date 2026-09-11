// proxymock CNCF demo app (Node.js). Exposes a small HTTP API on :8080 and fulfills
// each request by calling the CNCF downstream API. Zero dependencies (built-in http +
// global fetch). For proxymock recording, run on Node 24+ (or 22.21+) with
// NODE_USE_ENV_PROXY=1 and NODE_EXTRA_CA_CERTS set — see node/README.md.
import http from "node:http";
import crypto from "node:crypto";

const DOWNSTREAM = process.env.DOWNSTREAM_URL || "https://demo-api.trafficreplay.com";
const PORT = process.env.PORT || 8080;

// In-memory auth + order state. access_token and order_id are the two unique IDs
// that "move around": the token (POST /oauth/token) rides in the Authorization
// header; the order_id (POST /api/orders) rides in the GET /api/orders/{id} path.
const validTokens = new Set();
const orders = new Map();
const randId = (prefix, n) => prefix + crypto.randomBytes(n).toString("hex");
const readBody = (req) =>
  new Promise((resolve) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => resolve(b));
  });
const authed = (req) => {
  const h = req.headers["authorization"] || "";
  return h.startsWith("Bearer ") && validTokens.has(h.slice(7));
};

const sendJSON = (res, code, obj) => {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(obj));
};

const proxy = async (res, path) => {
  const r = await fetch(DOWNSTREAM + path);
  const text = await r.text();
  res.writeHead(r.status, { "content-type": "application/json" });
  res.end(text);
};

// Return the downstream category list plus a total of the per-category counts, so
// callers do not have to sum it themselves.
const categories = async (res) => {
  const r = await fetch(DOWNSTREAM + "/v1/categories");
  const payload = await r.json();
  if (!Array.isArray(payload.categories)) {
    return sendJSON(res, 500, { error: "cannot read category list" });
  }
  const total = payload.categories.reduce((n, c) => n + c.count, 0);
  sendJSON(res, 200, { categories: payload.categories, total });
};

const server = http.createServer(async (req, res) => {
  const p = req.url;
  const m = req.method;
  try {
    if (m === "POST" && p === "/oauth/token") {
      const token = randId("", 32);
      validTokens.add(token);
      sendJSON(res, 200, { access_token: token, token_type: "Bearer", expires_in: 3600 });
    } else if (m === "POST" && p === "/api/orders") {
      if (!authed(req)) return sendJSON(res, 401, { error: "missing or invalid bearer token" });
      let project = "";
      try { project = JSON.parse(await readBody(req)).project || ""; } catch {}
      if (!project) return sendJSON(res, 400, { error: "project is required" });
      const r = await fetch(DOWNSTREAM + "/v1/project/" + project);
      if (r.status !== 200) return sendJSON(res, 404, { error: "unknown project", project });
      const order = { order_id: randId("order-", 8), project, status: "created", created: new Date().toISOString() };
      orders.set(order.order_id, order);
      sendJSON(res, 201, order);
    } else if (m === "GET" && p.startsWith("/api/orders/")) {
      if (!authed(req)) return sendJSON(res, 401, { error: "missing or invalid bearer token" });
      const order = orders.get(p.slice("/api/orders/".length));
      if (!order) return sendJSON(res, 404, { error: "order not found" });
      sendJSON(res, 200, order);
    } else if (p === "/") {
      sendJSON(res, 200, { service: "proxymock-cncf-demo", lang: "node", downstream: DOWNSTREAM });
    } else if (p === "/api/projects") {
      await proxy(res, "/v1/projects");
    } else if (p.startsWith("/api/projects/")) {
      await proxy(res, "/v1/project/" + p.slice("/api/projects/".length));
    } else if (p === "/api/categories") {
      await categories(res);
    } else if (p === "/api/stats") {
      const r = await fetch(DOWNSTREAM + "/v1/projects");
      const projects = await r.json();
      const byMaturity = {};
      for (const proj of projects) byMaturity[proj.maturity] = (byMaturity[proj.maturity] || 0) + 1;
      sendJSON(res, 200, { total: projects.length, by_maturity: byMaturity });
    } else {
      sendJSON(res, 404, { error: "not found" });
    }
  } catch (e) {
    sendJSON(res, 502, { error: String(e) });
  }
});

server.listen(PORT, () => console.log(`node demo on :${PORT} (downstream=${DOWNSTREAM})`));
