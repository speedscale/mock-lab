import http from "node:http";
import crypto from "node:crypto";

const PORT = process.env.PORT || 8080;

const validTokens = new Set();
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
      sendJSON(res, 200, { account: user, orders: 0 });
    } else if (m === "POST" && p === "/oauth/token") {
      const token = randId("", 32);
      validTokens.add(token);
      sendJSON(res, 200, { access_token: token, token_type: "Bearer", expires_in: 3600 });
    } else if (m === "GET" && p.startsWith("/api/orders/")) {
      if (!authed(req)) return sendJSON(res, 401, { error: "missing or invalid bearer token" });
      sendJSON(res, 404, { error: "order not found" });
    } else if (m === "GET" && p === "/") {
      sendJSON(res, 200, { service: "credential-lab" });
    } else {
      sendJSON(res, 404, { error: "not found" });
    }
  } catch (e) {
    sendJSON(res, 502, { error: String(e) });
  }
});

server.listen(PORT, () => console.log(`credential lab on :${PORT}`));
