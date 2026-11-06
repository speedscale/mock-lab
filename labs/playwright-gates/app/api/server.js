// The API the project explorer calls, over the CNCF dataset the shared reference
// server uses. No dependencies, so it runs on a stock node image.
//
// LATENCY_MS delays every response. It is the backend slowdown the performance
// gate has to catch.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const port = Number(process.env.PORT || 8082);
const latencyMs = Number(process.env.LATENCY_MS || 0);
const projects = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '..', '..', '..', 'shared', 'server', 'data', 'projects.json'), 'utf8'),
).sort((a, b) => b.stars - a.stars);
// In memory, so a write journey can run as often as it likes and a restart resets it.
const tracked = new Set();

function send(res, status, body) {
  const payload = body === undefined ? '' : JSON.stringify(body);
  setTimeout(() => {
    res.writeHead(status, body === undefined ? {} : { 'Content-Type': 'application/json' });
    res.end(payload);
  }, latencyMs);
}

function summary(p) {
  return { id: p.id, name: p.name, maturity: p.maturity, category: p.category, stars: p.stars };
}

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Access-Control-Allow-Origin', req.headers.origin || '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Vary', 'Origin');

  if (req.method === 'OPTIONS') return send(res, 204);
  if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true });

  if (req.method === 'GET' && url.pathname === '/v1/projects') {
    const q = (url.searchParams.get('q') || '').toLowerCase();
    const maturity = url.searchParams.get('maturity') || '';
    const hits = projects.filter((p) =>
      (!q || p.name.toLowerCase().includes(q) || p.description.toLowerCase().includes(q)) &&
      (!maturity || p.maturity === maturity));
    return send(res, 200, hits.map(summary));
  }

  if (req.method === 'GET' && url.pathname === '/v1/categories') {
    const counts = {};
    for (const p of projects) counts[p.category] = (counts[p.category] || 0) + 1;
    return send(res, 200, Object.entries(counts)
      .map(([category, count]) => ({ category, count }))
      .sort((a, b) => b.count - a.count || a.category.localeCompare(b.category)));
  }

  const detail = url.pathname.match(/^\/v1\/projects\/([a-z0-9-]+)$/);
  if (req.method === 'GET' && detail) {
    const p = projects.find((x) => x.id === detail[1]);
    return p ? send(res, 200, { ...p, tracking: tracked.has(p.id) }) : send(res, 404, { error: 'not found' });
  }

  const track = url.pathname.match(/^\/v1\/projects\/([a-z0-9-]+)\/track$/);
  if (req.method === 'POST' && track) {
    if (!projects.some((x) => x.id === track[1])) return send(res, 404, { error: 'not found' });
    tracked.add(track[1]);
    return send(res, 200, { id: track[1], tracking: true });
  }

  if (req.method === 'DELETE' && track) {
    tracked.delete(track[1]);
    return send(res, 204);
  }

  return send(res, 404, { error: 'not found' });
}).listen(port, () => console.log(`explorer-api on :${port}${latencyMs ? `, ${latencyMs}ms latency` : ''}`));
