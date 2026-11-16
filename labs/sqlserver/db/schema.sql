-- The lab's shop database: products, orders, and a stored procedure for the
-- report. The app signs in as the SQL Server login "app". Running it again
-- resets the data, so every recording starts from the same rows.
IF DB_ID(N'shop') IS NULL CREATE DATABASE shop;
GO
IF SUSER_ID(N'app') IS NULL
    CREATE LOGIN app WITH PASSWORD = N'Lab-App-2026!', DEFAULT_DATABASE = shop, CHECK_POLICY = OFF;
GO
USE shop;
GO
IF USER_ID(N'app') IS NULL CREATE USER app FOR LOGIN app;
ALTER ROLE db_datareader ADD MEMBER app;
ALTER ROLE db_datawriter ADD MEMBER app;
GO
DROP PROCEDURE IF EXISTS dbo.top_products;
DROP TABLE IF EXISTS dbo.orders;
DROP TABLE IF EXISTS dbo.products;
GO
CREATE TABLE dbo.products (
    id          int IDENTITY(1,1) PRIMARY KEY,
    sku         varchar(20)   NOT NULL CONSTRAINT uq_products_sku UNIQUE,
    name        nvarchar(100) NOT NULL,
    category    varchar(20)   NOT NULL,
    price_cents int           NOT NULL,
    stock       int           NOT NULL CONSTRAINT ck_products_stock CHECK (stock >= 0)
);
CREATE TABLE dbo.orders (
    id          int IDENTITY(1,1) PRIMARY KEY,
    product_id  int NOT NULL REFERENCES dbo.products (id),
    quantity    int NOT NULL CHECK (quantity > 0),
    total_cents int NOT NULL
);
GO
INSERT INTO dbo.products (sku, name, category, price_cents, stock) VALUES
    ('BK-ROAD-58',  N'Road bike, 58 cm',        'bikes',       129900, 4),
    ('BK-MTN-L',    N'Mountain bike, large',    'bikes',       154900, 2),
    ('BK-CITY-M',   N'City bike, medium',       'bikes',        74900, 6),
    ('HL-AERO',     N'Aero helmet',             'accessories',  18900, 12),
    ('LT-USB',      N'USB rear light',          'accessories',   2900, 40),
    ('BT-750',      N'Water bottle, 750 ml',    'accessories',    900, 100),
    ('TR-700-28',   N'Tire 700×28c',            'parts',          4500, 30),
    ('CH-11S',      N'Chain, 11 speed',         'parts',          3900, 1),
    ('PD-CLIP',     N'Clipless pedals',         'parts',          8900, 8);
GO
-- Called by name as an RPC, so the recording holds a stored procedure call
-- with an OUTPUT parameter and a return status next to the plain statements.
CREATE PROCEDURE dbo.top_products @limit int, @total int OUTPUT AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@limit) p.id, p.name, SUM(o.quantity) AS sold
    FROM dbo.orders o JOIN dbo.products p ON p.id = o.product_id
    GROUP BY p.id, p.name
    ORDER BY sold DESC, p.id;
    SELECT @total = COUNT(*) FROM dbo.orders;
    RETURN 0;
END
GO
GRANT EXECUTE ON dbo.top_products TO app;
GO
