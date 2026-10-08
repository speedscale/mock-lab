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

// Public fixture credentials for replay demos, not a production login service.
const demoJWTSecret = "mock-lab-demo-signing-key";
const demoBasicUsers = new Map([["acme", "acme-secret"], ["globex", "globex-secret"]]);
const signJWT = (sub) => {
  const iat = Math.floor(Date.now() / 1000);
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({ sub, iss: "mock-lab", iat, exp: iat + 86400 })).toString("base64url");
  const signing = `${header}.${payload}`;
  return `${signing}.${crypto.createHmac("sha256", demoJWTSecret).update(signing).digest("base64url")}`;
};
const jwtSubject = (authorization = "") => {
  if (!authorization.startsWith("Bearer ")) return null;
  const parts = authorization.slice(7).split(".");
  if (parts.length !== 3) return null;
  try {
    const header = JSON.parse(Buffer.from(parts[0], "base64url"));
    const claims = JSON.parse(Buffer.from(parts[1], "base64url"));
    const signature = Buffer.from(parts[2], "base64url");
    const expected = crypto.createHmac("sha256", demoJWTSecret).update(`${parts[0]}.${parts[1]}`).digest();
    if (header.alg !== "HS256" || signature.length !== expected.length || !crypto.timingSafeEqual(signature, expected)) return null;
    if (claims.iss !== "mock-lab" || typeof claims.sub !== "string" || !claims.sub.trim()) return null;
    if (!Number.isSafeInteger(claims.exp) || claims.exp <= Math.floor(Date.now() / 1000)) return null;
    return claims.sub;
  } catch {
    return null;
  }
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

export const server = http.createServer(async (req, res) => {
  const p = req.url;
  const m = req.method;
  res.on("finish", () => console.log(`${m} ${p} -> ${res.statusCode}`));
  try {
    if (m === "POST" && p === "/auth/login") {
      let username;
      try { username = JSON.parse(await readBody(req))?.username; } catch {}
      if (typeof username !== "string" || !username.trim()) return sendJSON(res, 400, { error: "username is required" });
      const sub = username.trim();
      sendJSON(res, 200, { access_token: signJWT(sub), token_type: "Bearer", expires_in: 86400, subject: sub });
    } else if (m === "GET" && p === "/api/profile") {
      const sub = jwtSubject(req.headers.authorization);
      if (!sub) return sendJSON(res, 401, { error: "missing or invalid JWT bearer" });
      sendJSON(res, 200, { subject: sub, plan: "pro" });
    } else if (m === "GET" && p === "/api/account") {
      const authorization = req.headers.authorization || "";
      const decoded = authorization.startsWith("Basic ") ? Buffer.from(authorization.slice(6), "base64").toString() : "";
      const colon = decoded.indexOf(":");
      const user = decoded.slice(0, colon);
      const password = decoded.slice(colon + 1);
      if (colon < 0 || !demoBasicUsers.has(user) || demoBasicUsers.get(user) !== password) {
        res.setHeader("WWW-Authenticate", 'Basic realm="mock-lab"');
        return sendJSON(res, 401, { error: "invalid basic credentials" });
      }
      sendJSON(res, 200, { account: user, orders: orders.size });
    } else if (m === "POST" && p === "/oauth/token") {
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
      await proxy(res, "/v1/categories");
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
