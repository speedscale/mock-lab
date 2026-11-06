// Serves app/site on http://localhost:3000, standing in for your frontend's dev server.
//
// API_BASE is where the page sends its API calls (default http://api.localtest.me:8082).
// SITE_BUG=search ships the frontend regression the lab's gate has to catch: the
// search box sends ?query= instead of ?q=, so search silently stops filtering.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const port = Number(process.env.PORT || 3000);
const config = {
  apiBase: process.env.API_BASE || 'http://api.localtest.me:8082',
  bug: process.env.SITE_BUG || '',
};
const page = fs.readFileSync(path.join(__dirname, 'site', 'index.html'), 'utf8')
  .replace('/*CONFIG*/', `window.EXPLORER = ${JSON.stringify(config)};`);

http.createServer((req, res) => {
  const known = req.url === '/' || req.url === '/index.html';
  res.writeHead(known ? 200 : 404, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(known ? page : '');
}).listen(port, () => console.log(`explorer-site on http://localhost:${port}, API ${config.apiBase}${config.bug ? `, bug: ${config.bug}` : ''}`));
