/* ============================================================
   PROJECT : UrbanThread E-commerce Sales Performance
   AUTHOR  : Suman Aswal
   DATE    : 29-Oct-2026
   DATABASE: PostgreSQL (urbanthread)
   PURPOSE : Clean raw Amazon India sales data and answer
             the client's business questions
   ============================================================ */

-- ---------- STAGE 1A: CREATE SCHEMAS AND RAW TABLE ----------
-- Why: keep the original data untouched in "raw"; all fixes go to "clean".

CREATE SCHEMA raw;
CREATE SCHEMA clean;

CREATE TABLE raw.amazon_sales (
    index            TEXT,
    order_id         TEXT,
    order_date       TEXT,
    status           TEXT,
    fulfilment       TEXT,
    sales_channel    TEXT,
    ship_service     TEXT,
    style            TEXT,
    sku              TEXT,
    category         TEXT,
    size             TEXT,
    asin             TEXT,
    courier_status   TEXT,
    qty              TEXT,
    currency         TEXT,
    amount           TEXT,
    ship_city        TEXT,
    ship_state       TEXT,
    ship_postal_code TEXT,
    ship_country     TEXT,
    promotion_ids    TEXT,
    b2b              TEXT,
    fulfilled_by     TEXT,
    unnamed_22       TEXT
);

-- ---------- STAGE 1A: SANITY CHECK ----------
-- Result: 128,975 rows, 24 columns, no import errors.
-- Date format observed: MM-DD-YY (e.g. 04-30-22).

SELECT * FROM raw.amazon_sales LIMIT 10;
SELECT COUNT(*) FROM raw.amazon_sales;