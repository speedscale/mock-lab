// The Node.js version of the sqlserver lab's shop API, on the mssql package (tedious).
import http from 'node:http';
import sql from 'mssql';

const env = (name, def) => process.env[name] || def;

const pool = new sql.ConnectionPool({
  server: env('DB_HOST', 'localhost'),
  port: Number(env('DB_PORT', '11433')),
  database: env('DB_NAME', 'shop'),
  user: env('DB_USER', 'app'),
  password: env('DB_PASSWORD', 'Lab-App-2026!'),
  pool: { max: 4 },
  options: { encrypt: true, trustServerCertificate: true, appName: 'shop-node' },
});
const ready = pool.connect();

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function reply(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function positive(value) {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) throw new HttpError(400, 'bad request');
  return n;
}

async function readJSON(req) {
  let body = '';
  for await (const chunk of req) body += chunk;
  try {
    return JSON.parse(body);
  } catch {
    throw new HttpError(400, 'bad request');
  }
}

const product = (r) => ({ id: r.id, sku: r.sku, name: r.name, price_cents: r.price_cents, stock: r.stock });

async function health() {
  await pool.request().query('SELECT 1');
  return [200, { status: 'ok' }];
}

async function listProducts(url) {
  const result = await pool
    .request()
    .input('category', sql.VarChar(20), url.searchParams.get('category') ?? '')
    .query('SELECT id, sku, name, price_cents, stock FROM dbo.products WHERE category = @category ORDER BY id');
  return [200, { products: result.recordset.map(product) }];
}

async function getProduct(id) {
  const result = await pool
    .request()
    .input('id', sql.Int, id)
    .query('SELECT id, sku, name, price_cents, stock FROM dbo.products WHERE id = @id');
  if (result.recordset.length === 0) throw new HttpError(404, 'not found');
  return [200, product(result.recordset[0])];
}

// placeOrder takes the stock and records the order in one transaction, so two orders cannot sell the same unit.
async function placeOrder(req) {
  const input = await readJSON(req);
  const productID = positive(input.product_id);
  const quantity = positive(input.quantity);
  const tx = new sql.Transaction(pool);
  await tx.begin();
  try {
    const found = await new sql.Request(tx)
      .input('id', sql.Int, productID)
      .query('SELECT price_cents, stock FROM dbo.products WITH (UPDLOCK) WHERE id = @id');
    if (found.recordset.length === 0) throw new HttpError(404, 'not found');
    const { price_cents: price, stock } = found.recordset[0];
    if (stock < quantity) throw new HttpError(409, 'out of stock');
    await new sql.Request(tx)
      .input('quantity', sql.Int, quantity)
      .input('id', sql.Int, productID)
      .query('UPDATE dbo.products SET stock = stock - @quantity WHERE id = @id');
    const total = price * quantity;
    const inserted = await new sql.Request(tx)
      .input('id', sql.Int, productID)
      .input('quantity', sql.Int, quantity)
      .input('total', sql.Int, total)
      .query(
        'INSERT INTO dbo.orders (product_id, quantity, total_cents) OUTPUT INSERTED.id VALUES (@id, @quantity, @total)',
      );
    await tx.commit();
    return [201, { id: inserted.recordset[0].id, product_id: productID, quantity, total_cents: total }];
  } catch (err) {
    await tx.rollback().catch(() => {});
    throw err;
  }
}

async function getOrder(id) {
  const result = await pool
    .request()
    .input('id', sql.Int, id)
    .query(
      'SELECT o.id, o.product_id, p.name, o.quantity, o.total_cents FROM dbo.orders o ' +
        'JOIN dbo.products p ON p.id = o.product_id WHERE o.id = @id',
    );
  if (result.recordset.length === 0) throw new HttpError(404, 'not found');
  const r = result.recordset[0];
  return [200, { id: r.id, product_id: r.product_id, name: r.name, quantity: r.quantity, total_cents: r.total_cents }];
}

async function topProducts(url) {
  const limit = Number(url.searchParams.get('limit'));
  const result = await pool
    .request()
    .input('limit', sql.Int, Number.isInteger(limit) && limit > 0 ? limit : 3)
    .output('total', sql.Int)
    .execute('dbo.top_products');
  const top = result.recordset.map((r) => ({ id: r.id, name: r.name, sold: r.sold }));
  return [200, { orders: result.output.total, top }];
}

async function route(req, url) {
  const parts = url.pathname.split('/').filter(Boolean);
  if (req.method === 'GET' && url.pathname === '/health') return health();
  if (req.method === 'GET' && url.pathname === '/products') return listProducts(url);
  if (req.method === 'GET' && parts[0] === 'products' && parts.length === 2) return getProduct(positive(parts[1]));
  if (req.method === 'POST' && url.pathname === '/orders') return placeOrder(req);
  if (req.method === 'GET' && parts[0] === 'orders' && parts.length === 2) return getOrder(positive(parts[1]));
  if (req.method === 'GET' && url.pathname === '/reports/top-products') return topProducts(url);
  throw new HttpError(404, 'not found');
}

const port = Number(env('PORT', '8080'));
http
  .createServer(async (req, res) => {
    try {
      await ready;
      const [status, body] = await route(req, new URL(req.url, 'http://localhost'));
      reply(res, status, body);
    } catch (err) {
      if (err instanceof HttpError) return reply(res, err.status, { error: err.message });
      console.error(err);
      reply(res, 500, { error: `database: ${err.message}` });
    }
  })
  .listen(port, () => console.log(`shop-node listening on :${port}, database ${env('DB_HOST', 'localhost')}:${env('DB_PORT', '11433')}`));
