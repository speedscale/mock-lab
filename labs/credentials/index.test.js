import assert from "node:assert/strict";
import { once } from "node:events";
import { after, test } from "node:test";

process.env.PORT = "0";
const { server } = await import("./index.js");
if (!server.listening) await once(server, "listening");
const base = `http://127.0.0.1:${server.address().port}`;
after(() => new Promise((resolve) => server.close(resolve)));
const basic = (credentials) => ({ Authorization: `Basic ${Buffer.from(credentials).toString("base64")}` });

test("JWT login and profile preserve each subject", async () => {
  for (const username of ["alice", "bob"]) {
    const login = await fetch(`${base}/auth/login`, { method: "POST", body: JSON.stringify({ username }) });
    assert.equal(login.status, 200);
    const body = await login.json();
    assert.equal(body.subject, username);
    assert.equal(body.token_type, "Bearer");
    const claims = JSON.parse(Buffer.from(body.access_token.split(".")[1], "base64url"));
    assert.equal(claims.sub, username);
    assert.ok(claims.exp > Date.now() / 1000);
    const profile = await fetch(`${base}/api/profile`, { headers: { Authorization: `Bearer ${body.access_token}` } });
    assert.equal(profile.status, 200);
    assert.deepEqual(await profile.json(), { subject: username, plan: "pro" });
    const [header, payload, signature] = body.access_token.split(".");
    const tampered = `${header}.${payload}.${signature.startsWith("A") ? "B" : "A"}${signature.slice(1)}`;
    assert.equal((await fetch(`${base}/api/profile`, { headers: { Authorization: `Bearer ${tampered}` } })).status, 401);
  }
});

test("profile rejects missing, malformed, expired and invalid JWTs", async () => {
  assert.equal((await fetch(`${base}/api/profile`)).status, 401);
  const tokens = {
    "malformed": "not-a-jwt",
    "expired": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbGljZSIsImlzcyI6Im1vY2stbGFiIiwiZXhwIjoxfQ.ZF7w2u_U3iMPJEew2u9rZXOzbK6LBwgUpbr693-qN-w",
    "missing expiry": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbGljZSIsImlzcyI6Im1vY2stbGFiIn0.lM8KT_Ku224l7W_-CAcn2XrUTY_b-2v7yBiMXGQUbjc",
    "wrong algorithm": "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbGljZSIsImlzcyI6Im1vY2stbGFiIiwiZXhwIjo0MTAyNDQ0ODAwfQ.Vk0n07uINcqUwV0ZmssZTCF0hqCVtTZEggiVq_h17-w"
};
  for (const [name, token] of Object.entries(tokens)) {
    const response = await fetch(`${base}/api/profile`, { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(response.status, 401, name);
  }
});

test("login rejects invalid usernames and malformed JSON", async () => {
  for (const body of ["{", "null", "{}", '{"username":" "}', '{"username":1}']) {
    const response = await fetch(`${base}/auth/login`, { method: "POST", body });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: "username is required" });
  }
});

test("Basic accounts accept only the demo credential set", async () => {
  for (const [user, password] of [["acme", "acme-secret"], ["globex", "globex-secret"]]) {
    const response = await fetch(`${base}/api/account`, { headers: basic(`${user}:${password}`) });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { account: user, orders: 0 });
  }
  for (const credentials of ["not-a-demo-user:", "acme:", "acme:wrong", "toString:", "acme"]) {
    const response = await fetch(`${base}/api/account`, { headers: basic(credentials) });
    assert.equal(response.status, 401, credentials);
    assert.equal(response.headers.get("www-authenticate"), 'Basic realm="mock-lab"');
  }
  assert.equal((await fetch(`${base}/api/account`)).status, 401);
});

test("opaque bearer flow remains distinct", async () => {
  const response = await fetch(`${base}/oauth/token`, { method: "POST" });
  assert.equal(response.status, 200);
  const { access_token } = await response.json();
  assert.equal((await fetch(`${base}/api/profile`, { headers: { Authorization: `Bearer ${access_token}` } })).status, 401);
  assert.equal((await fetch(`${base}/api/orders/missing`, { headers: { Authorization: `Bearer ${access_token}` } })).status, 404);
});
