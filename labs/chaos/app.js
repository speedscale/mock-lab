import http from "node:http";
import { pathToFileURL } from "node:url";

export async function fetchStock(base, sku, timeoutMs = 5000) {
  const response = await fetch(`${base}/v1/inventory/${sku}`, { signal: AbortSignal.timeout(timeoutMs) });
  return await response.json();
}

export function createServer(inventoryURL = "http://localhost:8090", timeoutMs = 5000) {
  const lastKnown = new Map();
  return http.createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/healthz") return res.end("ok");
    if (req.method !== "GET" || !req.url.startsWith("/api/stock/")) {
      res.writeHead(404);
      return res.end();
    }
    const sku = req.url.slice("/api/stock/".length);
    res.setHeader("Content-Type", "application/json");
    try {
      const level = await fetchStock(inventoryURL, sku, timeoutMs);
      lastKnown.set(sku, level);
      res.end(JSON.stringify({ sku: level.sku, available: level.available, in_stock: level.available > 0, degraded: false, source: "inventory" }) + "\n");
    } catch (error) {
      const cached = lastKnown.get(sku);
      if (!cached) {
        res.writeHead(503);
        res.end(JSON.stringify({ error: "inventory unavailable" }) + "\n");
      } else {
        res.end(JSON.stringify({ sku, available: cached.available, in_stock: cached.available > 0, degraded: true, source: "cache" }) + "\n");
      }
      console.error(JSON.stringify({ sku, error: String(error), cached: Boolean(cached) }));
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createServer(process.env.INVENTORY_URL).listen(Number(process.env.PORT || 8080), "127.0.0.1", () => console.log("storefront ready"));
}
