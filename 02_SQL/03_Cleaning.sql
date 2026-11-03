/* ============================================================
   PROJECT  : UrbanThread E-commerce Sales Performance
   FILE     : 02_cleaning.sql
   AUTHOR   : Suman Aswal
   DATE     : <today>
   DATABASE : PostgreSQL. Reads schema raw, writes schema clean.
   PURPOSE  : Build clean.sales from raw.amazon_sales.
              Every rule below links to an Issue Log ID (e.g. [Issue 8]).
   ============================================================ */

-- [C1] STATUS MAPPING TABLE                                     [Issue 4]
-- What I do : store the status -> status_group rules in one small table
-- Why       : 13 detailed statuses cannot be used directly for net revenue; a table
--             makes the rule visible, editable and reusable
DROP TABLE IF EXISTS clean.status_map;
CREATE TABLE clean.status_map (
    raw_status   TEXT PRIMARY KEY,
    status_group TEXT NOT NULL
);

INSERT INTO clean.status_map (raw_status, status_group) VALUES
    ('Shipped',                       'Completed'),
    ('Shipped - Delivered to Buyer',  'Completed'),
    ('Shipped - Picked Up',           'Completed'),
    ('Shipped - Out for Delivery',    'Completed'),
    ('Cancelled',                     'Cancelled'),
    ('Shipped - Returned to Seller',  'Returned'),
    ('Shipped - Returning to Seller', 'Returned'),
    ('Shipped - Rejected by Buyer',   'Returned'),
    ('Pending',                       'In progress'),
    ('Pending - Waiting for Pick Up', 'In progress'),
    ('Shipping',                      'In progress'),
    ('Shipped - Lost in Transit',     'Lost/Damaged'),
    ('Shipped - Damaged',             'Lost/Damaged');

-- [C1 check] DOES EVERY ROW GET A GROUP?
-- What I check : join raw statuses to the mapping table and count rows per group
-- Why          : a status with no match would silently disappear from reports
-- Result: 		: Completed 107,581 | Cancelled 18,332 | Returned 2,109 | In progress 947 | Lost/Damaged 6
--         		= 128,975. No unmatched status.
SELECT
    m.status_group,
    COUNT(*) AS n
FROM raw.amazon_sales r
LEFT JOIN clean.status_map m
       ON r.status = m.raw_status
GROUP BY m.status_group
ORDER BY n DESC;



-- [C2] STATE MAPPING TABLE (EXCEPTIONS ONLY)              [Issues 9, 10, 11, 16]
-- What I do : list the state values that case-fixing cannot repair
-- Why       : aliases, typos and abbreviations would otherwise appear as extra
--             "states" in the client's regional ranking. Keys are stored in
--             UPPER CASE and trimmed, so the join also fixes the trailing space
--             on ANDAMAN & NICOBAR.
DROP TABLE IF EXISTS clean.state_map;
CREATE TABLE clean.state_map (
    raw_state   TEXT PRIMARY KEY,   -- upper case, trimmed
    clean_state TEXT NOT NULL
);

INSERT INTO clean.state_map (raw_state, clean_state) VALUES
    ('NEW DELHI',                'Delhi'),               -- alias
    ('ORISSA',                   'Odisha'),              -- old name
    ('PONDICHERRY',              'Puducherry'),          -- old name
    ('RAJSHTHAN',                'Rajasthan'),           -- typo
    ('RAJSTHAN',                 'Rajasthan'),           -- typo
    ('RJ',                       'Rajasthan'),           -- abbreviation, verified A15
    ('PB',                       'Punjab'),              -- abbreviation, verified A15
    ('PUNJAB/MOHALI/ZIRAKPUR',   'Punjab'),              -- city list in state field, A15
    ('NL',                       'Nagaland'),            -- abbreviation, verified A15
    ('AR',                       'Arunachal Pradesh'),   -- abbreviation, verified A15
    ('APO',                      'Unknown'),             -- army post office, no state
    ('DADRA AND NAGAR',          'Dadra and Nagar Haveli and Daman and Diu');



-- [C2 check] DOES THE STATE RULE WORK ON EVERY ROW?
-- What I check : number of distinct clean states, rows labelled Unknown, total rows
-- Why          : a leftover variant would inflate the state count; lost rows
--              would shrink the total
-- Result: 37 distinct states (36 real + Unknown); Unknown = 34 rows (33 NULL + 1 APO);
--         total 128,975. No rows lost.
SELECT
    COUNT(DISTINCT clean_state)                  AS distinct_states,
    COUNT(*) FILTER (WHERE clean_state = 'Unknown') AS unknown_rows,
    COUNT(*)                                     AS total_rows
FROM (
    SELECT
        COALESCE(m.clean_state,
                 INITCAP(UPPER(TRIM(r.ship_state))),
                 'Unknown') AS clean_state
    FROM raw.amazon_sales r
    LEFT JOIN clean.state_map m
           ON UPPER(TRIM(r.ship_state)) = m.raw_state
) AS cleaned;


-- [C3] CITY MAPPING TABLE (EXACT ALIASES)                       [Issue 19]
-- What I do : map old city names to current official names
-- Why       : the same city under two names splits its sales in the city ranking.
--             Keys are upper case with repeated spaces collapsed.
--             Thiruvananthapuram has 4 variants and is handled by a pattern rule
--             in the clean table instead (A27b).
DROP TABLE IF EXISTS clean.city_map;
CREATE TABLE clean.city_map (
    raw_city   TEXT PRIMARY KEY,   -- upper case, spaces collapsed
    clean_city TEXT NOT NULL
);

INSERT INTO clean.city_map (raw_city, clean_city) VALUES
    ('BANGALORE', 'Bengaluru'),
    ('GURGAON',   'Gurugram'),
    ('ALLAHABAD', 'Prayagraj'),
    ('MYSORE',    'Mysuru'),
    ('MANGALORE', 'Mangaluru'),
    ('BARODA',    'Vadodara'),
    ('COCHIN',    'Kochi'),
    ('CALCUTTA',  'Kolkata');

-- [C3 check] DO THE MERGED CITIES ADD UP?
-- What I check : row counts for the merged cities after cleaning
-- Why          : old names must disappear and the new names must hold the combined total
-- Result: Bengaluru 13,260 | Gurugram 2,292 | Prayagraj 368 | Thiruvananthapuram 744.
--         Old names no longer appear. The pattern rule caught 3 extra
--         Thiruvananthapuram variants (744 vs 741 from exact names).
WITH cleaned AS (
    SELECT 
        CASE
            WHEN r.city_key IS NULL                              THEN 'Unknown'
            WHEN r.city_key LIKE 'THIRUVANANTHAPUR%'
              OR r.city_key LIKE 'TRIVANDRUM%'                   THEN 'Thiruvananthapuram'
            ELSE COALESCE(m.clean_city, INITCAP(r.city_key))
        END AS clean_city
    FROM (
        SELECT UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_key
        FROM raw.amazon_sales
    ) r
    LEFT JOIN clean.city_map m
           ON r.city_key = m.raw_city
)
SELECT clean_city, COUNT(*) AS n
FROM cleaned
WHERE clean_city IN ('Bengaluru', 'Bangalore', 'Gurugram', 'Gurgaon',
                     'Prayagraj', 'Allahabad', 'Thiruvananthapuram', 'Trivandrum')
GROUP BY clean_city
ORDER BY n DESC;


-- [C3b] CITY VARIANTS HIDDEN BEHIND THE BIGGEST CITIES          [Issue 19]
-- What I check : for each big city, how many rows start with its name, how many
--                different spellings exist, and how many contain digits/punctuation
-- Why          : exact-name mapping misses variants such as BANGALORE-17 or
--                "Bangalore 560062"; I need the size of the problem before writing
--                a pattern rule
-- Finding      : 15 stems checked. Hidden variants (stem total minus exact name, from
--                A26/A27) total about 534 rows (0.4%). Bengaluru/Bangalore 83 rows,
--                Mumbai 91, Thane 134 (7% of its exact count, highest relative
--                share), others under 2%. City ranking order is unchanged.
--                Variants are suffixes (digits, punctuation, area names) and typos.
--                Decision: one boundary rule plus a short typo list, not a hunt.
--                Thane is checked for different towns in C3c.
WITH keys AS (
    SELECT UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_key
    FROM raw.amazon_sales
    WHERE ship_city IS NOT NULL
),
stems(stem) AS (
    VALUES ('BANGAL'), ('BENGAL'), ('HYDERABAD'), ('MUMBAI'), ('NEW DELHI'),
           ('CHENNAI'), ('PUNE'), ('KOLKATA'), ('GURUGRAM'), ('GURGAON'),
           ('THANE'), ('LUCKNOW'), ('NOIDA'), ('GHAZIABAD'), ('AHMEDABAD')
)
SELECT
    s.stem,
    COUNT(*)                                  AS rows_starting_with_stem,
    COUNT(DISTINCT k.city_key)                AS distinct_spellings,
    COUNT(*) FILTER (WHERE k.city_key ~ '[^A-Z ]') AS rows_with_digits_or_punctuation
FROM keys k
JOIN stems s ON k.city_key LIKE s.stem || '%'
GROUP BY s.stem
ORDER BY rows_starting_with_stem DESC;


-- [C4] LIST OF ROWS REMOVED FROM THE CLEAN TABLE                [Issues 1, 2]
-- What I do : record the row number (index) and the reason for every removed row
-- Why       : the raw table stays untouched; this table is the audit trail.
--             The duplicate check is repeated on the REAL date, because A2 compared
--             dates as text and could have missed a duplicate in the other format.
DROP TABLE IF EXISTS clean.removed_rows;
CREATE TABLE clean.removed_rows AS
WITH dated AS (
    SELECT
        *,
        CASE WHEN order_date ~ '^\d{2}-\d{2}-\d{4}$' THEN TO_DATE(order_date, 'MM-DD-YYYY')
             WHEN order_date ~ '^\d{2}-\d{2}-\d{2}$' THEN TO_DATE(order_date, 'MM-DD-YY')
        END AS order_dt
    FROM raw.amazon_sales
),
numbered AS (
    SELECT
        index,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, order_dt, status, fulfilment, sales_channel,
                         ship_service, style, sku, category, size, asin,
                         courier_status, qty, currency, amount, ship_city,
                         ship_state, ship_postal_code, ship_country,
                         promotion_ids, b2b, fulfilled_by
            ORDER BY index::int
        ) AS copy_number
    FROM dated
)
SELECT index, 'Exact duplicate' AS reason
FROM numbered
WHERE copy_number > 1
UNION ALL
SELECT d.index, 'Conflicting line item (no amount, valid twin exists)'
FROM dated d
WHERE d.amount IS NULL
  AND EXISTS (
      SELECT 1
      FROM dated o
      WHERE o.order_id = d.order_id
        AND o.sku      = d.sku
        AND o.size     = d.size
        AND o.index   <> d.index
        AND o.amount IS NOT NULL
  );


-- [C4 check] HOW MANY ROWS ARE REMOVED, AND WHY?
-- What I check : removed rows per reason
-- Why          : must match the audit (A2: 6 duplicates; A4: 1 conflicting row)
SELECT reason, COUNT(*) AS n
FROM clean.removed_rows
GROUP BY reason
ORDER BY n DESC;



select distinct
	ship_state,
	ship_city
from raw.amazon_sales
order by ship_city



























