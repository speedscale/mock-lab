// proxymock CNCF demo app (Node.js). Exposes a small HTTP API on :8080 and fulfills
// each request by calling the CNCF downstream API. Zero dependencies (built-in http +
// global fetch). For proxymock recording, route fetch through a proxy dispatcher or
// run behind proxymock per the Node language reference.
import http from "node:http";

const DOWNSTREAM = process.env.DOWNSTREAM_URL || "https://demo-api-dev.trafficreplay.com";
const PORT = process.env.PORT || 8080;

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

const server = http.createServer(async (req, res) => {
  const p = req.url;
  try {
    if (p === "/") {
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
