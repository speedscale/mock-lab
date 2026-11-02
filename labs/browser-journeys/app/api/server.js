// The API the shop SPA calls. No dependencies, so it runs on a stock node image.
//
// ITEM_FIELD renames the field that holds an item's name. Setting it to "title"
// is the backend change that "didn't touch the frontend" in this lab.
const http = require('node:http');

const port = Number(process.env.PORT || 8081);
const field = process.env.ITEM_FIELD || 'name';
const pages = { 1: ['apple', 'pear'], 2: ['plum', 'quince'] };

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');

  res.setHeader('Access-Control-Allow-Origin', req.headers.origin || '*');
  res.setHeader('Access-Control-Allow-Headers', 'X-Shop');
  res.setHeader('Vary', 'Origin');

  if (req.method === 'OPTIONS') {
    res.writeHead(204).end();
    return;
  }
  if (req.method !== 'GET' || url.pathname !== '/items') {
    res.writeHead(404).end();
    return;
  }

  const names = pages[url.searchParams.get('page') || '1'] || [];
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(names.map((name, i) => ({ id: i + 1, [field]: name }))));
}).listen(port, () => console.log(`shop-api on :${port}, item field "${field}"`));
