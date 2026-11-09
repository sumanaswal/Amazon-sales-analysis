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


-- [C3c] STEM MATCHES THAT THE BOUNDARY RULE WOULD NOT MERGE       [Issue 19]
-- What I check : values that start with a big-city stem but are NOT the city name
--                followed by a space, digit or punctuation
-- Why          : these are either typos to list explicitly or different towns that
--                must not be merged (a wrong merge is worse than a missed one)
-- Finding      : 28 leftover values, 48 rows (0.04%). None is a different town.
--                29 rows are a city name repeated or joined to an area name without a
--                separator (e.g. MUMBAIMUMBAI), 19 are typos or junk suffixes
--                (e.g. BENGALUR, NEW DELHIHBJO). Thane has no leftovers, so its
--                hidden variants are valid. Decision: merge any value starting
--                with the stem of one of these 15 cities (stem rule) instead of a
--                boundary rule. The conclusion holds only for the 15 stems checked.
WITH keys AS (
    SELECT UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_key
    FROM raw.amazon_sales
    WHERE ship_city IS NOT NULL
),
stems(stem, city_name) AS (
    VALUES ('BANGAL',    'BANGALORE'), ('BENGAL',    'BENGALURU'),
           ('HYDERABAD', 'HYDERABAD'), ('MUMBAI',    'MUMBAI'),
           ('NEW DELHI', 'NEW DELHI'), ('CHENNAI',   'CHENNAI'),
           ('PUNE',      'PUNE'),      ('KOLKATA',   'KOLKATA'),
           ('GURUGRAM',  'GURUGRAM'),  ('GURGAON',   'GURGAON'),
           ('THANE',     'THANE'),     ('LUCKNOW',   'LUCKNOW'),
           ('NOIDA',     'NOIDA'),     ('GHAZIABAD', 'GHAZIABAD'),
           ('AHMEDABAD', 'AHMEDABAD')
)
SELECT
    s.stem,
    k.city_key,
    COUNT(*) AS n
FROM keys k
JOIN stems s ON k.city_key LIKE s.stem || '%'
WHERE NOT (k.city_key ~ ('^' || s.city_name || '([^A-Z]|$)'))
GROUP BY s.stem, k.city_key
ORDER BY n DESC, s.stem
LIMIT 40;

-- [C3d] CITY STEM TABLE AND TOTALS CHECK                        [Issue 19]
-- What I do : store the 15 verified city stems (plus the Thiruvananthapuram
--             patterns) in a table; a city starting with a stem becomes that city
-- Why       : exact-name mapping missed postal codes, areas, typos and doubled names.
--             No stem starts with another stem, so a value can match only one stem
--             and no row can be duplicated by the join.
DROP TABLE IF EXISTS clean.city_stem_map;
CREATE TABLE clean.city_stem_map (
    stem       TEXT PRIMARY KEY,   -- upper case
    clean_city TEXT NOT NULL
);

INSERT INTO clean.city_stem_map (stem, clean_city) VALUES
    ('BANGAL',           'Bengaluru'),
    ('BENGAL',           'Bengaluru'),
    ('HYDERABAD',        'Hyderabad'),
    ('MUMBAI',           'Mumbai'),
    ('NEW DELHI',        'New Delhi'),
	('DELHI',	         'New Delhi'),
    ('CHENNAI',          'Chennai'),
    ('PUNE',             'Pune'),
    ('KOLKATA',          'Kolkata'),
    ('GURUGRAM',         'Gurugram'),
    ('GURGAON',          'Gurugram'),
    ('THANE',            'Thane'),
    ('LUCKNOW',          'Lucknow'),
    ('NOIDA',            'Noida'),
    ('GHAZIABAD',        'Ghaziabad'),
    ('AHMEDABAD',        'Ahmedabad'),
    ('THIRUVANANTHAPUR', 'Thiruvananthapuram'),
    ('TRIVANDRUM',       'Thiruvananthapuram');


-- [C3d check] DO THE CITY TOTALS CHANGE AS EXPECTED, WITH NO ROW DUPLICATED?
-- What I check : total rows and the counts of five cities under the stem rule
-- Why          : total_rows must stay at 128,975 (a bigger number means a row matched
--                two stems); city counts must equal the stem totals from C3b
-- Result: total 128,975 (no row duplicated). Bengaluru 13,343 (BENGAL 11,954 + BANGAL 1,389),
--         Gurugram 2,300 (1,959 + 341), Mumbai 7,213, Thane 2,011,
--         Thiruvananthapuram 744. All equal the stem totals from C3b.
WITH keys AS (
    SELECT UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_key
    FROM raw.amazon_sales
),
cleaned AS (
    SELECT
        CASE
            WHEN k.city_key IS NULL        THEN 'Unknown'
            WHEN st.clean_city IS NOT NULL THEN st.clean_city
            ELSE COALESCE(cm.clean_city, INITCAP(k.city_key))
        END AS clean_city
    FROM keys k
    LEFT JOIN clean.city_stem_map st ON k.city_key LIKE st.stem || '%'
    LEFT JOIN clean.city_map      cm ON k.city_key = cm.raw_city
)
SELECT
    COUNT(*)                                              AS total_rows,
    COUNT(*) FILTER (WHERE clean_city = 'Bengaluru')      AS bengaluru,
    COUNT(*) FILTER (WHERE clean_city = 'Gurugram')       AS gurugram,
    COUNT(*) FILTER (WHERE clean_city = 'Mumbai')         AS mumbai,
    COUNT(*) FILTER (WHERE clean_city = 'Thane')          AS thane,
    COUNT(*) FILTER (WHERE clean_city = 'Thiruvananthapuram') AS thiruvananthapuram
FROM cleaned;


-- [C3e] SPELLING-TYPO CANDIDATES FOR THE BIG CITIES              [Issue 19]
-- What I check : first words of city values that the stem rule did NOT catch but that
--                are 1-2 letters away from a big city (e.g. BANGLORE, DELHIQ), with
--                row counts
-- Why          : found by manual search: Banglore, Bangluru, Banganlore and the Delhi
--                variants are missed by the stem rule. Real towns (Bangaon, Bangarapet)
--                share letters with Bangalore, so every candidate needs a human decision.
-- Finding      : 46 candidate spellings. 54 rows (0.04%) are typos of Bengaluru (20),
--                Ahmedabad (13), Hyderabad (9), Gurugram (5), Chennai (4), Mumbai (2)
--                and Kolkata (1); these are merged. The rest are real towns or cities
--                (e.g. MANGALURU 363, MEHMEDABAD, MUMBRA, GOREGAON) and are NOT merged,
--                or too unclear to decide (MUMBA, KOIDA, THANA).
--                Delhi: 368 rows start with DELHI (suffixes only, 2 more as DELHIQ);
--                this query cannot see swapped-letter typos such as DEHLI (see C3f).
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

WITH words AS (
    SELECT
        SUBSTRING(UPPER(TRIM(ship_city)) FROM '^[A-Z]+')              AS first_word,
        UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g'))       AS city_key
    FROM raw.amazon_sales
    WHERE ship_city IS NOT NULL
),
unmatched AS (
    SELECT first_word, COUNT(*) AS n, MIN(city_key) AS example
    FROM words w
    WHERE first_word IS NOT NULL
      AND LENGTH(first_word) <= 30
      AND NOT EXISTS (SELECT 1 FROM clean.city_stem_map st
                      WHERE w.city_key LIKE st.stem || '%')
    GROUP BY first_word
),
targets(target) AS (
    VALUES ('BANGALORE'), ('BENGALURU'), ('HYDERABAD'), ('MUMBAI'), ('CHENNAI'),
           ('PUNE'), ('KOLKATA'), ('GURUGRAM'), ('GURGAON'), ('THANE'),
           ('LUCKNOW'), ('NOIDA'), ('GHAZIABAD'), ('AHMEDABAD'), ('DELHI')
)
SELECT
    t.target,
    u.first_word,
    levenshtein(u.first_word, t.target) AS distance,
    u.n                                 AS rows_affected,
    u.example
FROM unmatched u
JOIN targets t
  ON levenshtein(u.first_word, t.target)
     <= CASE WHEN LENGTH(t.target) <= 5 THEN 1 ELSE 2 END
ORDER BY t.target, distance, u.n DESC;


-- [C3f] DELHI SPELLING VARIANTS (REVISED)                       [Issue 19]
-- What I check : every word within 2 edits of DELHI, in any position of the city value,
--                outside values already covered by the NEW DELHI stem, with row counts
-- Why          : first version excluded the exact word DELHI, which hid the suffix
--                variants (Delhi-92., Delhi Cantt); a spelling check was needed for
--                typos such as DEHLI that a LIKE 'Del%' search cannot find
-- Finding      : (fill in after running)
WITH words AS (
    SELECT
        t.word,
        UPPER(REGEXP_REPLACE(TRIM(r.ship_city), '\s+', ' ', 'g')) AS city_key
    FROM raw.amazon_sales r,
         LATERAL REGEXP_SPLIT_TO_TABLE(UPPER(TRIM(r.ship_city)), '[^A-Z]+') AS t(word)
    WHERE r.ship_city IS NOT NULL
)
SELECT
    word,
    levenshtein(word, 'DELHI') AS distance,
    COUNT(*)                   AS rows_affected,
    MIN(city_key)              AS example
FROM words
WHERE LENGTH(word) BETWEEN 4 AND 7
  AND levenshtein(word, 'DELHI') <= 2
  AND city_key NOT LIKE 'NEW DELHI%'
GROUP BY word
ORDER BY distance, rows_affected DESC;

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


--###########################################

-- [C5] BUILD THE CLEAN TABLE                       [Issues 1-19, 21: see comments]
-- What I do : create clean.sales from raw.amazon_sales with all fixes applied
-- Why       : analysis, Excel and Power BI must read one trusted table, never the raw data
DROP TABLE IF EXISTS clean.sales;
CREATE TABLE clean.sales AS
WITH base AS (
    SELECT
        r.*,
        CASE WHEN r.order_date ~ '^\d{2}-\d{2}-\d{4}$' THEN TO_DATE(r.order_date, 'MM-DD-YYYY')
             WHEN r.order_date ~ '^\d{2}-\d{2}-\d{2}$' THEN TO_DATE(r.order_date, 'MM-DD-YY')
        END                                                              AS order_dt,   -- [Issue 8]
        UPPER(REGEXP_REPLACE(TRIM(r.ship_city), '\s+', ' ', 'g'))        AS city_key,
        UPPER(TRIM(r.ship_state))                                        AS state_key
    FROM raw.amazon_sales r
    WHERE NOT EXISTS (SELECT 1 FROM clean.removed_rows x WHERE x.index = r.index)  -- [Issues 1, 2]
)
SELECT
    b.index::int                                         AS row_id,          -- renamed from index
    b.order_id,
    b.order_dt                                           AS order_date,      -- real DATE
    b.status,
    sm.status_group,                                                         -- [Issue 4]
    b.fulfilment,
    b.sales_channel,
    b.ship_service,
    b.style,
    REGEXP_REPLACE(b.sku, '\s+', ' ', 'g')               AS sku,             -- [Issue 17]
    b.asin,
    INITCAP(b.category)                                  AS category,        -- [Issue 12]
    b.size,
    b.courier_status,
    b.qty::int                                           AS qty,
    b.amount::numeric(12,2)                              AS amount,
    COALESCE(stm.clean_state, INITCAP(b.state_key), 'Unknown')  AS ship_state,  -- [Issues 9-11, 16]
    CASE
        WHEN b.city_key IS NULL              THEN 'Unknown'
        WHEN cst.clean_city IS NOT NULL      THEN cst.clean_city
        ELSE COALESCE(cm.clean_city, INITCAP(b.city_key))
    END                                                  AS ship_city,       -- [Issues 18, 19]
    b.b2b::boolean                                       AS is_b2b,
    (b.promotion_ids IS NOT NULL)                        AS has_promotion,
    ( (b.status = 'Shipped' AND b.courier_status IN ('Unshipped', 'Cancelled'))
   OR (b.status = 'Pending' AND b.courier_status IN ('Shipped', 'Cancelled')) )
                                                         AS has_status_conflict,   -- [Issue 3]
    ( (b.amount IS NULL OR b.amount::numeric = 0)
      AND b.status <> 'Cancelled' )                      AS amount_missing_or_zero -- [Issues 6, 20]
FROM base b
LEFT JOIN clean.status_map sm  ON b.status    = sm.raw_status
LEFT JOIN clean.state_map  stm ON b.state_key = stm.raw_state
LEFT JOIN clean.city_map   cm  ON b.city_key  = cm.raw_city
LEFT JOIN clean.city_stem_map cst ON b.city_key LIKE cst.stem || '%';

ALTER TABLE clean.sales ADD PRIMARY KEY (row_id);

select * from clean.city_stem_map;
-- [C5 check] DOES THE CLEAN TABLE RECONCILE WITH THE AUDIT?
-- What I check : row count, flags, unmatched groups, and the date range
-- Why          : every number must be explainable from an audit finding
-- Result: 128,968 rows (128,975 - 7 removed); 219 status conflicts (220 - 1 removed);
--         2,571 missing/zero amounts (2,572 - 1 removed); 0 rows without status group;
--         2022-03-31 to 2022-06-29. All explained by C4.
SELECT
    COUNT(*)                                          AS total_rows,
    COUNT(*) FILTER (WHERE has_status_conflict)       AS status_conflicts,
    COUNT(*) FILTER (WHERE amount_missing_or_zero)    AS missing_or_zero,
    COUNT(*) FILTER (WHERE status_group IS NULL)      AS no_group,
    MIN(order_date)                                   AS first_day,
    MAX(order_date)                                   AS last_day
FROM clean.sales;


-- [C6 check] DELHI RULE ON THE CLEAN TABLE                       [Issue 19]
-- What I check : every city value containing DELHI after the rebuild, with row counts
-- Why          : proves the stem rule merged all Delhi spellings into New Delhi, and shows
--                whether values with DELHI in the MIDDLE (South Delhi, Dwarka Delhi) remain
-- Finding      : New Delhi = 6,748 rows (stem NEW DELHI 6,378 + DELHI family 370):
--                the DELHI stem rule works. 179 further rows (0.14%) contain DELHI
--                in the middle or end: 159 Delhi districts typed as the city (East
--                Delhi 54, South West Delhi 32...), 6 spelling variants (N.Delhi,
--                Newdelhi, New-Delhi) and 14 neighbourhood + Delhi values. All are
--                Delhi; none is another place. Not merged: no effect on the city
--                ranking (New Delhi stays 4th), and the state column is already
--                correct for these rows.
SELECT
    ship_city,
    COUNT(*) AS rows_n
FROM clean.sales
WHERE ship_city ILIKE '%DELHI%'
GROUP BY ship_city
ORDER BY rows_n DESC;



-- [C7 final check] DOES THE CLEAN TABLE ACCOUNT FOR EVERY RAW ROW?
-- What I check : raw rows = removed rows + clean rows
-- Why          : proves the script lost or invented nothing; difference must be 0
-- Result: raw 128,975 = removed 7 + clean 128,968. Difference 0.
--         The script rebuilds clean.sales from raw data with no manual steps.
SELECT
    (SELECT COUNT(*) FROM raw.amazon_sales)       AS raw_rows,
    (SELECT COUNT(*) FROM clean.removed_rows)     AS removed_rows,
    (SELECT COUNT(*) FROM clean.sales)            AS clean_rows,
    (SELECT COUNT(*) FROM raw.amazon_sales)
      - (SELECT COUNT(*) FROM clean.removed_rows)
      - (SELECT COUNT(*) FROM clean.sales)        AS difference;



SELECT * FROM clean.sales ORDER BY row_id;



-- [C8] DELIVERED/RETURNED LINES WITHOUT AMOUNT VS WITHOUT COURIER STATUS     [Issue 7]
-- What I check : for Delivered and Returned-to-Seller lines, how many have a NULL amount,
--                how many have a NULL courier_status, and how many have both
-- Why          : A5 and A7 each found 8 Delivered and 3 Returned lines; the same counts do
--                not prove the same lines. If both_null equals both counts, they are the
--                same incomplete lines and Issue 7 can be closed
-- Finding      : Delivered: 8 lines with NULL amount, 8 with NULL courier_status, 8 with both.
--                Returned-to-Seller: 3, 3 and 3. So the 11 lines without amount (A7) and the 11
--                without courier_status (A5) are the same lines (Easy Ship; these statuses exist
--                only for Easy Ship, S15b). Kept, flagged amount_missing_or_zero, excluded from
--                net revenue; effect under INR 6,000 (under 0.01%).
SELECT
    status,
    COUNT(*) FILTER (WHERE amount IS NULL)                            AS amount_null,
    COUNT(*) FILTER (WHERE courier_status IS NULL)                    AS courier_null,
    COUNT(*) FILTER (WHERE amount IS NULL AND courier_status IS NULL) AS both_null
FROM clean.sales
WHERE status IN ('Shipped - Delivered to Buyer', 'Shipped - Returned to Seller')
GROUP BY status
ORDER BY status;

















