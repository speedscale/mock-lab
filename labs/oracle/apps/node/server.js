// The Node.js version of the oracle lab's shop API, on node-oracledb in thin mode (the default).
import http from 'node:http';
import oracledb from 'oracledb';

const env = (name, def) => process.env[name] || def;

oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;

const ready = oracledb.createPool({
  user: env('DB_USER', 'shop'),
  password: env('DB_PASSWORD', 'LabShop2026'),
  connectString: `${env('DB_HOST', 'localhost')}:${env('DB_PORT', '11521')}/${env('DB_SERVICE', 'FREEPDB1')}`,
  poolMin: 0,
  poolMax: 4,
});

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

// withConnection lends a pooled connection to fn and returns it to the pool afterwards.
async function withConnection(fn) {
  const conn = await (await ready).getConnection();
  try {
    return await fn(conn);
  } finally {
    await conn.close();
  }
}

const product = (r) => ({ id: r.ID, sku: r.SKU, name: r.NAME, price_cents: r.PRICE_CENTS, stock: r.STOCK });

async function health() {
  await withConnection((conn) => conn.execute('SELECT 1 FROM dual'));
  return [200, { status: 'ok' }];
}

async function listProducts(url) {
  const result = await withConnection((conn) =>
    conn.execute('SELECT id, sku, name, price_cents, stock FROM products WHERE category = :category ORDER BY id', {
      category: url.searchParams.get('category') ?? '',
    }),
  );
  return [200, { products: result.rows.map(product) }];
}

async function getProduct(id) {
  const result = await withConnection((conn) =>
    conn.execute('SELECT id, sku, name, price_cents, stock FROM products WHERE id = :id', { id }),
  );
  if (result.rows.length === 0) throw new HttpError(404, 'not found');
  return [200, product(result.rows[0])];
}

// placeOrder takes the stock and records the order in one transaction, so two orders cannot sell the same unit.
async function placeOrder(req) {
  const input = await readJSON(req);
  const productID = positive(input.product_id);
  const quantity = positive(input.quantity);
  return withConnection(async (conn) => {
    try {
      const found = await conn.execute('SELECT price_cents, stock FROM products WHERE id = :id FOR UPDATE', {
        id: productID,
      });
      if (found.rows.length === 0) throw new HttpError(404, 'not found');
      const { PRICE_CENTS: price, STOCK: stock } = found.rows[0];
      if (stock < quantity) throw new HttpError(409, 'out of stock');
      await conn.execute('UPDATE products SET stock = stock - :quantity WHERE id = :id', {
        quantity,
        id: productID,
      });
      const total = price * quantity;
      const inserted = await conn.execute(
        'INSERT INTO orders (product_id, quantity, total_cents) VALUES (:product_id, :quantity, :total) ' +
          'RETURNING id INTO :order_id',
        {
          product_id: productID,
          quantity,
          total,
          order_id: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
        },
      );
      await conn.commit();
      return [201, { id: inserted.outBinds.order_id[0], product_id: productID, quantity, total_cents: total }];
    } catch (err) {
      await conn.rollback().catch(() => {});
      throw err;
    }
  });
}

async function getOrder(id) {
  const result = await withConnection((conn) =>
    conn.execute(
      'SELECT o.id, o.product_id, p.name, o.quantity, o.total_cents FROM orders o ' +
        'JOIN products p ON p.id = o.product_id WHERE o.id = :id',
      { id },
    ),
  );
  if (result.rows.length === 0) throw new HttpError(404, 'not found');
  const r = result.rows[0];
  return [200, { id: r.ID, product_id: r.PRODUCT_ID, name: r.NAME, quantity: r.QUANTITY, total_cents: r.TOTAL_CENTS }];
}

// topProducts calls the top_products procedure, which returns its rows as a REF CURSOR OUT parameter.
async function topProducts(url) {
  const limit = Number(url.searchParams.get('limit'));
  return withConnection(async (conn) => {
    const result = await conn.execute('BEGIN top_products(:limit, :total, :top); END;', {
      limit: Number.isInteger(limit) && limit > 0 ? limit : 3,
      total: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
      top: { dir: oracledb.BIND_OUT, type: oracledb.CURSOR },
    });
    const cursor = result.outBinds.top;
    const rows = await cursor.getRows();
    await cursor.close();
    const top = rows.map((r) => ({ id: r.ID, name: r.NAME, sold: r.SOLD }));
    return [200, { orders: result.outBinds.total, top }];
  });
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
      const [status, body] = await route(req, new URL(req.url, 'http://localhost'));
      reply(res, status, body);
    } catch (err) {
      if (err instanceof HttpError) return reply(res, err.status, { error: err.message });
      console.error(err);
      reply(res, 500, { error: `database: ${err.message}` });
    }
  })
  .listen(port, () => console.log(`shop-node listening on :${port}, database ${env('DB_HOST', 'localhost')}:${env('DB_PORT', '11521')}`));
