import http from "node:http";

const catalog = new Map([
  ["SSC-4110", [42, "ATL-1", 10]],
  ["SSC-4111", [7, "ATL-1", 10]],
  ["SSC-5200", [118, "PDX-2", 25]],
  ["SSC-5201", [0, "PDX-2", 25]],
  ["SSC-6100", [63, "ATL-1", 15]],
  ["SSC-7300", [9, "DFW-3", 20]],
]);

http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") return res.end("ok");
  const sku = req.url.slice("/v1/inventory/".length);
  const level = req.method === "GET" && req.url.startsWith("/v1/inventory/") && catalog.get(sku);
  res.setHeader("Content-Type", "application/json");
  if (!level) {
    res.writeHead(404);
    return res.end(JSON.stringify({ error: "unknown sku" }) + "\n");
  }
  const [available, warehouse_id, reorder_point] = level;
  res.end(JSON.stringify({ sku, available, warehouse_id, reorder_point }) + "\n");
}).listen(8090, "127.0.0.1", () => console.log("inventory ready"));
