import assert from "node:assert/strict";
import http from "node:http";
import { once } from "node:events";
import { test } from "node:test";
import { createServer, fetchStock } from "./app.js";

const stock = { sku: "SSC-4110", available: 42, warehouse_id: "ATL-1", reorder_point: 10 };

test("client exercises successful JSON, invalid JSON and connection errors", async (t) => {
  const inventory = http.createServer((req, res) => {
    res.end(req.url.endsWith("invalid") ? "not json" : JSON.stringify(stock));
  }).listen(0, "127.0.0.1");
  await once(inventory, "listening");
  const base = `http://127.0.0.1:${inventory.address().port}`;
  t.after(() => new Promise((resolve) => inventory.close(resolve)));
  assert.deepEqual(await fetchStock(base, "SSC-4110"), stock);
  await assert.rejects(fetchStock(base, "invalid"), SyntaxError);
  await new Promise((resolve) => inventory.close(resolve));
  await assert.rejects(fetchStock(base, "SSC-4110"), TypeError);
});

test("storefront handles healthy, cached and unavailable paths", async (t) => {
  let invalid = false;
  const inventory = http.createServer((req, res) => res.end(invalid ? "not json" : JSON.stringify(stock))).listen(0, "127.0.0.1");
  await once(inventory, "listening");
  const app = createServer(`http://127.0.0.1:${inventory.address().port}`).listen(0, "127.0.0.1");
  await once(app, "listening");
  t.after(() => Promise.all([new Promise((resolve) => app.close(resolve)), new Promise((resolve) => inventory.close(resolve))]));
  const base = `http://127.0.0.1:${app.address().port}`;
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/missing`)).status, 404);
  const healthy = await fetch(`${base}/api/stock/SSC-4110`);
  assert.equal(healthy.status, 200);
  assert.deepEqual(await healthy.json(), { sku: "SSC-4110", available: 42, in_stock: true, degraded: false, source: "inventory" });
  invalid = true;
  const cached = await fetch(`${base}/api/stock/SSC-4110`);
  assert.equal(cached.status, 200);
  assert.deepEqual(await cached.json(), { sku: "SSC-4110", available: 42, in_stock: true, degraded: true, source: "cache" });
  const unavailable = await fetch(`${base}/api/stock/SSC-5201`);
  assert.equal(unavailable.status, 503);
  assert.deepEqual(await unavailable.json(), { error: "inventory unavailable" });
});
