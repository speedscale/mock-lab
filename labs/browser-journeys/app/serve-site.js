// Serves app/site on http://localhost:3000, standing in for your frontend's dev server.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const port = Number(process.env.PORT || 3000);
const page = fs.readFileSync(path.join(__dirname, 'site', 'index.html'));

http.createServer((req, res) => {
  const known = req.url === '/' || req.url === '/index.html';
  res.writeHead(known ? 200 : 404, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(known ? page : '');
}).listen(port, () => console.log(`shop-spa on http://localhost:${port}`));
