/* ============================================================
   PROJECT  : UrbanThread E-commerce Sales Performance
   FILE     : 01_audit.sql
   AUTHOR   : Suman Aswal
   DATE     : 01-Sep-2026
   DATABASE : PostgreSQL, schema raw
   PURPOSE  : Find every data quality problem BEFORE cleaning.
              This script only reads data. It changes nothing.
   ============================================================ */

-- [A1] GRAIN CHECK
-- What I check : are order_ids unique, or do they repeat?
-- Why          : a repeated order_id is normal if an order has several items,
--                so I must not treat it as a duplicate yet.
-- Finding      : 128,975 rows but only 120,378 distinct order_ids, so 8,597
--                (6.67%) extra rows beyond the first row of each order_id. Cause unknown yet:
--                could be multi-item orders (valid) or duplicated rows (error).
--                See A2 to separate the two.
SELECT
    COUNT(*)                            AS total_rows,
    COUNT(DISTINCT order_id)            AS distinct_orders,
    COUNT(*) - COUNT(DISTINCT order_id) AS repeated_rows
FROM raw.amazon_sales;

-- [A2] EXACT DUPLICATE CHECK
-- What I check : rows identical in every column except index (the export row number)
-- Why          : these are surplus copies that would inflate revenue if kept
-- Finding      : 6 exact duplicate rows (0.005%) found. 128,969 unique rows remain.
--                Almost all of the 8,597 repeated order_ids are therefore NOT
--                exact copies. Next check (A3) examines whether they are
--                valid multi-item orders.
WITH numbered AS (
    SELECT
        index,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, order_date, status, fulfilment, sales_channel,
                         ship_service, style, sku, category, size, asin,
                         courier_status, qty, currency, amount, ship_city,
                         ship_state, ship_postal_code, ship_country,
                         promotion_ids, b2b, fulfilled_by
            ORDER BY index
        ) AS copy_number
    FROM raw.amazon_sales
)
SELECT
    COUNT(*) FILTER (WHERE copy_number = 1) AS rows_to_keep,
    COUNT(*) FILTER (WHERE copy_number > 1) AS exact_duplicates_to_remove,
    COUNT(*)                                AS total_rows
FROM numbered;

-- [A3] SUSPICIOUS REPEATS CHECK
-- What I check : orders where the same order_id + sku + size appears more than once
-- Why          : a genuine multi-item order has DIFFERENT products per row;
--                the same product repeated may be a data error
-- Finding      : 7 groups (14 rows) repeat the same order_id + sku + size, each
--                with exactly 2 rows. 6 are the exact duplicates already found
--                in A2. 1 pair differs in some other column and needs review (A4).
--                All other repeated order_ids hold different products, so they
--                are valid multi-item orders. Grain confirmed: 1 row = 1 order line.
SELECT
    COUNT(*)                          AS suspicious_groups,
    COALESCE(SUM(rows_in_group), 0)   AS rows_involved
FROM (
    SELECT order_id, sku, size, COUNT(*) AS rows_in_group
    FROM raw.amazon_sales
    GROUP BY order_id, sku, size
    HAVING COUNT(*) > 1
) AS repeats;

-- [A4] REVIEW OF REPEATED ORDER + SKU + SIZE ROWS
-- What I check : show the 14 rows from A3 side by side
-- Why          : find the one pair that is NOT an exact duplicate and see
--                which column differs
-- Finding      : 14 rows = 7 pairs. 6 pairs are exact copies (3 shipped, 3 cancelled),
--                matching A2. 1 pair (order 407-8364731-6449117) differs in
--                courier_status, qty, currency and amount: one row is a cancelled
--                attempt (qty 0, no amount) and the other a valid sale (qty 1, INR 487).
--                Decision: keep the valid sale, remove the conflicting row.
SELECT *
FROM raw.amazon_sales
WHERE (order_id, sku, size) IN (
	SELECT order_id, sku, size
	FROM raw.amazon_sales
	GROUP BY order_id, sku, size
	HAVING COUNT(*) > 1
)
ORDER BY order_id, sku, size, index;

-- [A5] STATUS vs COURIER_STATUS CONSISTENCY
-- What I check : every combination of status and courier_status, with row counts
-- Why          : the client's main measure is net revenue excluding cancelled and
--                returned orders, so I must know which column defines "cancelled"
--                and whether the two columns contradict each other
-- Finding      : 21 status/courier_status combinations; counts reconcile to 128,975.
--                status has 13 values and is the detailed column, so it defines
--                "cancelled" and "returned". Cancelled = 18,332 rows (14.2%);
--                returned-type (Returned/Returning to Seller, Rejected by Buyer)
--                = 2,109 rows (1.6%). courier_status has only 4 values and cannot
--                show returns. 220 rows contradict each other (Shipped/Unshipped 115,
--                Shipped/Cancelled 93, Pending/Shipped 10, Pending/Cancelled 2).
--                courier_status is NULL for 6,861 Cancelled rows (likely cancelled
--                before a courier was assigned, not an error). Amounts checked in A6.
SELECT
    status,
    courier_status,
    COUNT(*) AS n
FROM raw.amazon_sales
GROUP BY status, courier_status
ORDER BY status, n DESC;


-- [A6] AMOUNTS ON CONTRADICTING ROWS
-- What I check : for the 4 contradicting status/courier_status combinations,
--                how many rows have an amount, and how much money is involved
-- Why          : decides whether these rows can distort net revenue
-- Finding      : 210 of 220 contradicting rows have no amount, so they add no
--                revenue. Only 10 rows (Pending + courier Shipped) carry money:
--                INR 7,679. Decision: status is the authority; those 10 are treated
--                as "In progress" and excluded from net revenue (conservative).
--                The 208 Shipped rows with no amount are kept but flagged
--                (has_status_conflict) and excluded from order counts and AOV.
SELECT
    status,
    courier_status,
    COUNT(*)                                   AS n,
    COUNT(*) FILTER (WHERE amount IS NULL)     AS amount_null,
    COUNT(*) FILTER (WHERE amount IS NOT NULL) AS amount_present,
    COALESCE(SUM(amount::numeric), 0)          AS amount_total
FROM raw.amazon_sales
WHERE (status = 'Shipped' AND courier_status IN ('Unshipped', 'Cancelled'))
   OR (status = 'Pending' AND courier_status IN ('Shipped', 'Cancelled'))
GROUP BY status, courier_status
ORDER BY n DESC;


-- [A7] MISSING / ZERO / NON-NUMERIC AMOUNTS BY STATUS
-- What I check : for every status, how many rows have a null amount, a zero
--                amount, a non-numeric amount, or qty = 0
-- Why          : missing money on Cancelled orders is expected; missing money on
--                completed orders is a real data error that understates revenue
-- Finding      : Amounts are always numeric (0 non-numeric values). 7,795 rows
--                (6.0%) have a null amount: 208 Shipped + 2 Pending + 8 Shipping
--                are the contradicting rows from A5/A6; 7,566 are Cancelled;
--                11 are Delivered/Returned and look like incomplete records.
--                10,766 of 18,332 Cancelled rows (59%) still carry an amount,
--                so revenue must always be filtered by status. 2,343 rows (1.8%)
--                have a zero amount on non-cancelled orders: cause unknown, see A8.
SELECT
    status,
    COUNT(*)                                                         AS n,
    COUNT(*) FILTER (WHERE amount IS NULL)                           AS amount_null,
    COUNT(*) FILTER (WHERE amount ~ '^0+(\.0+)?$')                   AS amount_zero,
    COUNT(*) FILTER (WHERE amount IS NOT NULL
                       AND amount !~ '^-?\d+(\.\d+)?$')              AS amount_not_number,
    COUNT(*) FILTER (WHERE qty = '0')                                AS qty_zero
FROM raw.amazon_sales
GROUP BY status
ORDER BY n DESC;

-- [A8] ZERO-AMOUNT ROWS ON NON-CANCELLED ORDERS
-- What I check : among rows with amount = 0 (excluding Cancelled), the qty value,
--                and whether a promotion is attached
-- Why          : decides whether zero means a free/discounted item (valid, keep)
--                or missing data (error, exclude from revenue)
-- Finding      : 2,343 non-cancelled rows have amount = 0 (matches A7). All have
--                qty = 1. 781 (33.3%) carry a promotion, 1,562 (66.7%) have none.
--                The promotion does not explain most zeros. Need a baseline
--                (promotion rate on normal rows) before deciding, see A9.
SELECT
    qty,
    (promotion_ids IS NOT NULL) AS has_promotion,
    COUNT(*)                    AS n
FROM raw.amazon_sales
WHERE amount ~ '^0+(\.0+)?$'
  AND status <> 'Cancelled'
GROUP BY qty, (promotion_ids IS NOT NULL)
ORDER BY n DESC;

-- [A9] PROMOTION RATE BASELINE
-- What I check : share of rows with a promotion, split by amount type
--                (zero, null, positive), for non-cancelled rows
-- Why          : A8 showed 33% of zero-amount rows have a promotion. This tells me
--                whether that is unusual compared with normal sales
-- Finding      : Non-cancelled rows reconcile (110,643). 72.8% of normal
--                positive-amount rows carry a promotion, but only 33.3% of
--                zero-amount rows and 31.0% of null-amount rows do. The zero
--                rows look like the null rows (missing data), not like
--                promotional items. Decision: keep rows, flag them, exclude from
--                AOV and price averages. Client question Q1 stays open.
SELECT
    CASE WHEN amount IS NULL                 THEN 'null'
         WHEN amount ~ '^0+(\.0+)?$'         THEN 'zero'
         ELSE 'positive' END                 AS amount_type,
    COUNT(*)                                 AS n,
    COUNT(*) FILTER (WHERE promotion_ids IS NOT NULL) AS with_promotion,
    ROUND(100.0 * COUNT(*) FILTER (WHERE promotion_ids IS NOT NULL)
          / COUNT(*), 1)                     AS pct_with_promotion
FROM raw.amazon_sales
WHERE status <> 'Cancelled'
GROUP BY amount_type
ORDER BY n DESC;


-- [A10] DATE FORMAT PATTERNS
-- What I check : how many rows follow each date pattern in order_date
-- Why          : the column is text and formats are mixed; converting without
--                knowing the patterns could silently produce wrong dates
-- Finding      : Counts reconcile to 128,975. No null dates. Two formats mixed:
--                xx-xx-YY 73,866 rows (57.3%) and xx-xx-YYYY 55,109 rows (42.7%).
--                Example 03-31-22 suggests MM-DD-YY for the short format; the
--                order of the long format is unverified, see A11. Text min/max
--                are NOT real date ranges.
SELECT
    CASE WHEN order_date IS NULL                  THEN 'null'
         WHEN order_date ~ '^\d{2}-\d{2}-\d{2}$'  THEN 'xx-xx-YY'
         WHEN order_date ~ '^\d{2}-\d{2}-\d{4}$'  THEN 'xx-xx-YYYY'
         ELSE 'other' END       AS date_pattern,
    COUNT(*)                    AS n,
    MIN(order_date)             AS example_min,
    MAX(order_date)             AS example_max
FROM raw.amazon_sales
GROUP BY date_pattern
ORDER BY n DESC;

-- [A11] DATE PART RANGES BY FORMAT
-- What I check : smallest and largest value of the 1st and 2nd part of each date
--                pattern, and how many rows have a part above 12
-- Why          : a part above 12 cannot be a month, which proves the order (MM-DD
--                or DD-MM) for each format
-- Finding      : xx-xx-YY (73,866 rows): part1 = 3-6, part2 = 13-31, part2 > 12 in
--                every row, so the format is PROVEN MM-DD-YY.
--                xx-xx-YYYY (55,109 rows): part1 = 4-6, part2 = 1-12, no part > 12,
--                so the order cannot be proven by this test. Pattern: short format
--                holds only days 13-31, long format only days 1-12. This makes
--                MM-DD-YYYY the strong hypothesis (DD-MM would mean orders on
--                only 3 days of the month). To be verified in A12.
WITH parts AS (
    SELECT
        CASE WHEN order_date ~ '^\d{2}-\d{2}-\d{2}$' THEN 'xx-xx-YY'
             ELSE 'xx-xx-YYYY' END           AS date_pattern,
        SUBSTRING(order_date, 1, 2)::int     AS part1,
        SUBSTRING(order_date, 4, 2)::int     AS part2
    FROM raw.amazon_sales
    WHERE order_date ~ '^\d{2}-\d{2}-(\d{2}|\d{4})$'
)
SELECT
    date_pattern,
    COUNT(*)                          AS n,
    MIN(part1)                        AS part1_min,
    MAX(part1)                        AS part1_max,
    MIN(part2)                        AS part2_min,
    MAX(part2)                        AS part2_max,
    COUNT(*) FILTER (WHERE part1 > 12) AS part1_above_12,
    COUNT(*) FILTER (WHERE part2 > 12) AS part2_above_12
FROM parts
GROUP BY date_pattern;


-- [A12] LONG DATE FORMAT: MONTH vs DAY TEST
-- What I check : for the xx-xx-YYYY rows, how many distinct values the 2nd part
--                takes within each value of the 1st part
-- Why          : if the 1st part is the month, each month should show days 1-12
--                (12 distinct values); if it is the day, the data would look absurd
-- Finding      : Counts reconcile to 55,109. Each month (04, 05, 06) holds 12
--                distinct second-part values (01-12), as expected if part 1 is the
--                month. Combined with the daily count (A12b), where long dates
--                (days 1-12) continue exactly into short dates (days 13-31) with
--                no jumps, MM-DD-YYYY is VERIFIED for the long format.
SELECT
    SUBSTRING(order_date, 1, 2)                 AS part1,
    COUNT(*)                                    AS n,
    COUNT(DISTINCT SUBSTRING(order_date, 4, 2)) AS distinct_part2,
    MIN(SUBSTRING(order_date, 4, 2))            AS part2_min,
    MAX(SUBSTRING(order_date, 4, 2))            AS part2_max
FROM raw.amazon_sales
WHERE order_date ~ '^\d{2}-\d{2}-\d{4}$'
GROUP BY part1
ORDER BY part1;

-- [A12b] CHECKING DATE CONTINUTIY
-- What I check : for the continuation of dates
-- Why			: if dates are falling in line then the long format is certailnly MM-DD-YYYY
-- Finding		: Read month-first, this is one continuous calendar with daily volumes 
--				  between roughly 1,100 and 2,100 and no jumps.
--				  Read day-first, the long dates would be 4 January, 4 February, 4 March and so on, 
--				  and the daily series would break. So MM-DD-YYYY is now verified
SELECT order_date, count(*) AS counts
FROM raw.amazon_sales
GROUP BY order_date
ORDER BY order_date;

-- [A13] TRUE DATE RANGE AND MISSING DAYS
-- What I check : convert both formats to real dates, then find the earliest and
--                latest date, how many days have orders, and whether any day is missing
-- Why          : text min/max were meaningless; the client needs the real period
--                covered, and a missing day would distort weekly and monthly trends
-- Finding      : After converting both formats, the data runs from 2022-03-31 to
--                2022-06-29 (91 calendar days). All 91 days have orders, so no day
--                is missing. 0 rows failed conversion. March (1 day) and June
--                (29 days) are partial months; only April and May are full.
WITH converted AS (
    SELECT
        CASE WHEN order_date ~ '^\d{2}-\d{2}-\d{4}$' THEN TO_DATE(order_date, 'MM-DD-YYYY')
             WHEN order_date ~ '^\d{2}-\d{2}-\d{2}$' THEN TO_DATE(order_date, 'MM-DD-YY')
        END AS order_dt
    FROM raw.amazon_sales
)
SELECT
    MIN(order_dt)                            AS first_day,
    MAX(order_dt)                            AS last_day,
    COUNT(DISTINCT order_dt)                 AS days_with_orders,
    MAX(order_dt) - MIN(order_dt) + 1        AS calendar_days,
    COUNT(*) FILTER (WHERE order_dt IS NULL) AS unconverted_rows
FROM converted;


-- [A14] STATE NAME VARIANTS
-- What I check : every distinct ship_state value with its row count, plus a
--                normalised version (upper case, trimmed)
-- Why          : the same state written in different ways would split its
--                sales into several groups and distort the regional ranking
-- Finding      : 70 spellings, counts reconcile to 128,975. They collapse to 48
--                distinct values after UPPER/TRIM: 36 real states/UTs, 11 values
--                that case-fixing cannot repair (aliases New Delhi/Orissa/
--                Pondicherry, typos of Rajasthan, abbreviations RJ/PB/NL/AR,
--                APO, one city list in the state field) and NULL (33 rows).
--                About 408 rows differ only by letter case; 98 rows need a mapping.
SELECT
    ship_state,
    UPPER(TRIM(ship_state)) AS state_normalised,
    COUNT(*)                AS n
FROM raw.amazon_sales
GROUP BY ship_state
ORDER BY state_normalised, n DESC;

-- [A15] CHECK AMBIGUOUS STATE VALUES AGAINST CITY AND POSTAL CODE
-- What I check : city and postal code for the abbreviations and odd values
--                (APO, AR, NL, PB, RJ and the city list in the state field)
-- Why          : an abbreviation like AR can mean more than one state; the postal
--                code lets me decide from evidence instead of guessing
-- Finding      : 8 rows checked. City and postal code agree for every one:
--                AR -> Arunachal Pradesh (Itanagar 791113), NL -> Nagaland
--                (Dimapur 797116, 2 rows), PB -> Punjab (Zira 142044), the city
--                list -> Punjab (Zirakpur 140603), RJ -> Rajasthan (Jaipur 302029,
--                Jodhpur 342009). APO (postal 959121) is a military post office
--                with no state, so it becomes "Unknown".
SELECT
    ship_state,
    ship_city,
    ship_postal_code,
    COUNT(*) AS n
FROM raw.amazon_sales
WHERE ship_state IN ('APO', 'AR', 'NL', 'PB', 'RJ')
   OR ship_state LIKE 'Punjab/Mohali%'
GROUP BY ship_state, ship_city, ship_postal_code
ORDER BY ship_state;


-- [A16] RECOVER MISSING STATES FROM POSTAL CODE
-- What I check : for rows with a NULL state, the city, postal code, and which
--                states appear elsewhere in the table for the same postal code
-- Why          : if a postal code always maps to one state, the missing state can
--                be filled from evidence; if not, it must stay "Unknown"
-- Finding      : All 33 rows with a NULL state also have a NULL city and a NULL
--                postal code (no shipping address at all), so the state cannot be
--                recovered from any other column. Decision: label as "Unknown".
--                Impact on revenue is checked in A17.
SELECT
    s.ship_city,
    s.ship_postal_code,
    COUNT(*) AS n,
    (SELECT STRING_AGG(DISTINCT UPPER(TRIM(o.ship_state)), ' | ')
     FROM raw.amazon_sales o
     WHERE o.ship_postal_code = s.ship_postal_code
       AND o.ship_state IS NOT NULL) AS states_for_same_postal_code
FROM raw.amazon_sales s
WHERE s.ship_state IS NULL
GROUP BY s.ship_city, s.ship_postal_code
ORDER BY n DESC;


-- [A17] REVENUE IMPACT OF ROWS WITH NO SHIPPING ADDRESS
-- What I check : status, row count and amount of the 33 rows with a NULL state
-- Why          : decides whether "Unknown" is a harmless footnote or a visible
--                region in the client's state ranking
-- Finding      : The 33 no-address rows reconcile (16 Shipped, 7 Delivered,
--                7 Cancelled, 3 Returned). 31 carry an amount, INR 18,671 in total.
--                23 rows (Shipped + Delivered, INR 15,012) are completed sales that
--                count toward net revenue; the rest are excluded by status.
--                Decision: keep the rows, label the state "Unknown", and disclose
--                the revenue without a state on the dashboard.
SELECT
    status,
    COUNT(*)                                   AS n,
    COUNT(*) FILTER (WHERE amount IS NOT NULL) AS rows_with_amount,
    COALESCE(SUM(amount::numeric), 0)          AS amount_total
FROM raw.amazon_sales
WHERE ship_state IS NULL
GROUP BY status
ORDER BY n DESC;

-- [A18] VALUE LISTS FOR SMALL CATEGORY COLUMNS
-- What I check : every distinct value and its row count in each low-cardinality
--                text column
-- Why          : counts separate real categories from typos, and show which
--                columns hold a single value and add nothing to the analysis
-- Finding      : All columns reconcile to 128,975. No typos in size, fulfilment,
--                sales_channel or b2b. currency = INR (94.0%) or NULL (the same
--                7,795 rows as NULL amounts); ship_country = IN or NULL (the 33
--                no-address rows), so both are single-value and add no analytic
--                information. fulfilled_by counts match fulfilment exactly
--                (89,698 / 39,277), likely a duplicate column (see A19).
--                Category 'kurta' (49,877 rows) is lower case while other categories
--                are capitalised. sales_channel has 124 Non-Amazon rows (0.1%).
--                unnamed_22 is NOT empty (FALSE 79,925, NULL 49,050), see A20.
SELECT 'category' AS column_name, category AS value, COUNT(*) AS n
FROM raw.amazon_sales GROUP BY category
UNION ALL
SELECT 'size', size, COUNT(*) FROM raw.amazon_sales GROUP BY size
UNION ALL
SELECT 'fulfilment', fulfilment, COUNT(*) FROM raw.amazon_sales GROUP BY fulfilment
UNION ALL
SELECT 'sales_channel', sales_channel, COUNT(*) FROM raw.amazon_sales GROUP BY sales_channel
UNION ALL
SELECT 'currency', currency, COUNT(*) FROM raw.amazon_sales GROUP BY currency
UNION ALL
SELECT 'ship_country', ship_country, COUNT(*) FROM raw.amazon_sales GROUP BY ship_country
UNION ALL
SELECT 'b2b', b2b, COUNT(*) FROM raw.amazon_sales GROUP BY b2b
UNION ALL
SELECT 'fulfilled_by', fulfilled_by, COUNT(*) FROM raw.amazon_sales GROUP BY fulfilled_by
UNION ALL
SELECT 'unnamed_22', unnamed_22, COUNT(*) FROM raw.amazon_sales GROUP BY unnamed_22
ORDER BY column_name, n DESC;


-- [A19] FULFILMENT vs FULFILLED_BY
-- What I check : every combination of fulfilment and fulfilled_by, with counts
-- Why          : the column totals match, but only a row-by-row comparison shows
--                whether fulfilled_by adds any information or is a duplicate
-- Finding      : Counts reconcile to 128,975. Only 2 combinations exist:
--                Amazon + NULL (89,698) and Merchant + Easy Ship (39,277).
--                fulfilled_by is fully determined by fulfilment in every row, so
--                it adds no information. Its NULLs mean "not Easy Ship", not
--                missing data. Decision: drop fulfilled_by from the clean table
--                and use clearer labels for fulfilment (confirm with client).
SELECT
    fulfilment,
    fulfilled_by,
    COUNT(*) AS n
FROM raw.amazon_sales
GROUP BY fulfilment, fulfilled_by
ORDER BY n DESC;

-- [A20] IS UNNAMED_22 A MIRROR OF PROMOTION_IDS?
-- What I check : unnamed_22 against whether promotion_ids is present
-- Why          : the column has no name or documentation; if it is fully
--                explained by promotion_ids it carries no information of its own
-- Finding      : Counts reconcile to 128,975. All 4 combinations of unnamed_22
--                and promotion present/absent exist (48,985 / 30,940 / 30,837 /
--                18,213). FALSE rate is 61.4% with a promotion and 62.9% without,
--                so unnamed_22 is NOT a mirror of promotion_ids and is unrelated
--                to it. Meaning unknown. Earlier hypothesis (from 14 sample rows
--                in A4) was rejected. Next: test relation to row position (A21).
SELECT
    unnamed_22,
    (promotion_ids IS NOT NULL) AS has_promotion,
    COUNT(*)                    AS n
FROM raw.amazon_sales
GROUP BY unnamed_22, (promotion_ids IS NOT NULL)
ORDER BY n DESC;

-- [A21] IS UNNAMED_22 LINKED TO ROW POSITION?
-- What I check : for each block of 10,000 rows (by the export row number),
--                how many rows have unnamed_22 = FALSE and how many are NULL
-- Why          : a column that is filled for one part of the file and empty for
--                another suggests it was added by a different export step,
--                not by a business rule
-- Finding      : Blocks reconcile to 128,975 (FALSE 79,925, NULL 49,050, as in A18).
--                unnamed_22 is NULL for the first ~49,050 rows and FALSE for the
--                rest, with a single mixed block (40,000-49,999: 9,050 NULL then
--                950 FALSE). The column depends on row position, not on any business
--                attribute, so it is an export artefact. The earlier link to
--                promotions (A4) came from row position, not from promotions.
SELECT
    (index::int / 10000) * 10000                      AS block_start,
    COUNT(*)                                          AS n,
    COUNT(*) FILTER (WHERE unnamed_22 = 'FALSE')      AS false_rows,
    COUNT(*) FILTER (WHERE unnamed_22 IS NULL)        AS null_rows
FROM raw.amazon_sales
WHERE index ~ '^\d+$'
GROUP BY block_start
ORDER BY block_start;


-- [A22] HIDDEN SPACES IN TEXT COLUMNS
-- What I check : per column, how many values have spaces at the start or end,
--                or two or more spaces in a row
-- Why          : invisible spaces make identical-looking values count as
--                different groups and break joins and lookups
-- Finding      : order_id, status, size, category: no hidden spaces. ship_state:
--                257 values with leading/trailing spaces (same count as the
--                ANDAMAN & NICOBAR group in A14, to verify in A23). ship_city: 90
--                values with double spaces. sku: 166 values with double spaces.
--                Note: A14 hid the state spaces because it displayed TRIM().
SELECT 'order_id' AS column_name,
       COUNT(*) FILTER (WHERE order_id <> TRIM(order_id)) AS outer_spaces,
       COUNT(*) FILTER (WHERE order_id ~ '\s{2,}')        AS double_spaces
FROM raw.amazon_sales
UNION ALL
SELECT 'status',
       COUNT(*) FILTER (WHERE status <> TRIM(status)),
       COUNT(*) FILTER (WHERE status ~ '\s{2,}')
FROM raw.amazon_sales
UNION ALL
SELECT 'sku',
       COUNT(*) FILTER (WHERE sku <> TRIM(sku)),
       COUNT(*) FILTER (WHERE sku ~ '\s{2,}')
FROM raw.amazon_sales
UNION ALL
SELECT 'category',
       COUNT(*) FILTER (WHERE category <> TRIM(category)),
       COUNT(*) FILTER (WHERE category ~ '\s{2,}')
FROM raw.amazon_sales
UNION ALL
SELECT 'size',
       COUNT(*) FILTER (WHERE size <> TRIM(size)),
       COUNT(*) FILTER (WHERE size ~ '\s{2,}')
FROM raw.amazon_sales
UNION ALL
SELECT 'ship_city',
       COUNT(*) FILTER (WHERE ship_city <> TRIM(ship_city)),
       COUNT(*) FILTER (WHERE ship_city ~ '\s{2,}')
FROM raw.amazon_sales
UNION ALL
SELECT 'ship_state',
       COUNT(*) FILTER (WHERE ship_state <> TRIM(ship_state)),
       COUNT(*) FILTER (WHERE ship_state ~ '\s{2,}')
FROM raw.amazon_sales;

-- [A22b] WHICH STATES HAVE OUTER SPACES
-- What I check : states whose value changes when trimmed
-- Why          : A14 displayed TRIM(), so it hid this problem
-- Finding      : Only ANDAMAN & NICOBAR (257 rows) has outer spaces.
SELECT ship_state, COUNT(*) AS n
FROM raw.amazon_sales
WHERE ship_state <> TRIM(ship_state)
GROUP BY ship_state;

-- [A23] SHOW HIDDEN SPACES AS VISIBLE DOTS
-- What I check : the actual values with outer spaces (ship_state) or double
--                spaces (ship_city, sku), with each space shown as a dot
-- Why          : confirms which values are affected and whether the fix is a
--                simple TRIM or a collapse of repeated spaces
-- Finding      : ship_state: only ANDAMAN & NICOBAR (257 rows) has a trailing
--                space; fix with TRIM. ship_city: the double spaces sit inside
--                free-text values (street details, postal codes, delivery
--                instructions, district labels), so the city column is not a
--                clean city list. sku: a single value (166 rows) has a double
--                space; check for a clean twin in A24. Only the top 10 city
--                values were displayed (of 90 affected rows).
(SELECT 'ship_state' AS column_name,
        '[' || REPLACE(ship_state, ' ', '·') || ']' AS visible_value,
        COUNT(*) AS n
 FROM raw.amazon_sales
 WHERE ship_state <> TRIM(ship_state)
 GROUP BY ship_state
 ORDER BY n DESC LIMIT 10)
UNION ALL
(SELECT 'ship_city',
        '[' || REPLACE(ship_city, ' ', '·') || ']',
        COUNT(*)
 FROM raw.amazon_sales
 WHERE ship_city ~ '\s{2,}'
 GROUP BY ship_city
 ORDER BY COUNT(*) DESC LIMIT 10)
UNION ALL
(SELECT 'sku',
        '[' || REPLACE(sku, ' ', '·') || ']',
        COUNT(*)
 FROM raw.amazon_sales
 WHERE sku ~ '\s{2,}'
 GROUP BY sku
 ORDER BY COUNT(*) DESC LIMIT 10);


-- [A24] SKU SPELLINGS THAT DIFFER ONLY BY SPACES
-- What I check : SKUs that become identical once all spaces are removed, but
--                exist in the table in more than one spelling
-- Why          : a spacing difference would split one product into two in the
--                SKU ranking (client question 1)
-- Finding      : 0 rows returned. No SKU exists in more than one spelling that
--                differs only by spaces, so the 166-row double-space SKU
--                (SET397-KR-NP  M) does not split any product. Fix is cosmetic:
--                collapse repeated spaces in the clean table.
SELECT
    REGEXP_REPLACE(sku, '\s', '', 'g')                   AS sku_no_spaces,
    COUNT(DISTINCT sku)                                  AS spellings,
    STRING_AGG(DISTINCT '[' || REPLACE(sku, ' ', '·') || ']', ' | ') AS variants,
    COUNT(*)                                             AS n
FROM raw.amazon_sales
GROUP BY REGEXP_REPLACE(sku, '\s', '', 'g')
HAVING COUNT(DISTINCT sku) > 1;

-- [A25] SIZE AND SHAPE OF THE CITY COLUMN
-- What I check : number of distinct city values, how many look like free text
--                (contain digits, commas, brackets or are very long), and how
--                many rows they cover
-- Why          : decides whether a city ranking is reliable or needs heavy cleaning
-- Finding      : 8,955 distinct city spellings; 7,297 after UPPER/TRIM, so
--                1,658 are case/space variants of the same city. 2,081 rows (1.6%)
--                look like free text (1,382 distinct values, almost all unique).
--                33 NULLs (no-address rows). Decision: apply UPPER/TRIM and collapse
--                spaces to all rows; verify the top cities for spelling variants
--                (A26); report city results for the top cities and group the long
--                tail and free-text rows as "Other".
SELECT
    COUNT(DISTINCT ship_city)                                      AS distinct_cities,
    COUNT(DISTINCT UPPER(TRIM(ship_city)))                         AS distinct_after_case_trim,
    COUNT(*) FILTER (WHERE ship_city ~ '[0-9,()]' OR LENGTH(ship_city) > 30)
                                                                   AS rows_looking_like_free_text,
    COUNT(DISTINCT ship_city) FILTER (WHERE ship_city ~ '[0-9,()]' OR LENGTH(ship_city) > 30)
                                                                   AS distinct_free_text_values,
    COUNT(*) FILTER (WHERE ship_city IS NULL)                      AS city_null
FROM raw.amazon_sales;


-- [A26] TOP 30 CITIES AFTER BASIC CLEANING
-- What I check : the 30 biggest cities after UPPER/TRIM and collapsing spaces,
--                with their row counts and share of the table
-- Why          : the city ranking answers client question 2; I must see whether
--                the same city appears under different names
-- Finding      : Top 30 cities after UPPER/TRIM/space collapse look clean except
--                one confirmed pair: BENGALURU (11,898) and BANGALORE (1,362) are
--                the same city (combined 13,260 rows, 10.3%). NEW DELHI (6,340) is
--                kept as a city name. NAVI MUMBAI, GURUGRAM, NOIDA and GHAZIABAD
--                are separate cities. Display cut off one name (THIRUVANATHAPUR...);
--                other aliases (Gurgaon, Trivandrum) to be checked in A27.
SELECT
    UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_clean,
    COUNT(*)                                                AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)      AS pct_of_rows
FROM raw.amazon_sales
WHERE ship_city IS NOT NULL
GROUP BY city_clean
ORDER BY n DESC
LIMIT 30;


-- [A27] KNOWN CITY ALIASES
-- What I check : row counts for old or alternate names of major cities
-- Why          : the same city under two names would split its sales in the
--                city ranking (client question 2)
-- Finding      : 19 rows returned. Alias pairs found in both forms: Gurgaon 338 /
--                Gurugram 1,954; Allahabad 324 / Prayagraj 44; Mysore 66 / Mysuru
--                423; Mangalore 45 / Mangaluru 358; Baroda 6 / Vadodara 710;
--                Cochin 15 / Kochi 203; Trivandrum 62 / Thiruvananthapuram 679.
--                With Bangalore (A26) 2,218 rows (1.7%) sit under an old name.
--                Bombay, Madras and Poona not present; Calcutta 2 rows.
--                Decision: map to the current official names in a city mapping table.
SELECT
    UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_clean,
    COUNT(*)                                                AS n
FROM raw.amazon_sales
WHERE UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) IN
      ('GURGAON', 'GURUGRAM', 'TRIVANDRUM', 'THIRUVANANTHAPURAM',
       'BOMBAY', 'MUMBAI', 'MADRAS', 'CHENNAI', 'CALCUTTA', 'KOLKATA',
       'POONA', 'PUNE', 'COCHIN', 'KOCHI', 'BARODA', 'VADODARA',
       'MYSORE', 'MYSURU', 'MANGALORE', 'MANGALURU', 'ALLAHABAD', 'PRAYAGRAJ')
GROUP BY city_clean
ORDER BY city_clean;


-- [A27b] FULL SPELLING OF THE CUT-OFF CITY NAME
-- What I check : the complete text of the Thiruvananthapuram variant
-- Why          : the display truncated it; the mapping table needs the exact value
-- Finding      : 4 spellings: THIRUVANANTHAPURAM, THIRUVANANTHAPURAM 1,
--                THIRUVANANTHAPURAM DISTRICT (name cut off by the display) and
--                TRIVANDRUM. Decision: map all four with a pattern rule
--                (starts with THIRUVANANTHAPUR or TRIVANDRUM) to
--                "Thiruvananthapuram". Row counts per variant checked after cleaning.
SELECT DISTINCT
    UPPER(REGEXP_REPLACE(TRIM(ship_city), '\s+', ' ', 'g')) AS city_clean
FROM raw.amazon_sales
WHERE UPPER(ship_city) LIKE 'THIRUVANANTHAPUR%'
   OR UPPER(ship_city) LIKE 'TRIVANDRUM%';


-- [A28] QUANTITY DISTRIBUTION
-- What I check : each distinct qty value, with row count and total amount
-- Why          : decides whether rows equal units sold, and whether any
--                quantity looks unusual
-- Finding      : Counts reconcile to 128,975; all qty values are whole numbers.
--                qty 0 = 12,807 rows (INR 3.19M, mostly Cancelled, see A7);
--                qty 1 = 115,780; qty 2+ = 388 rows (0.3%) holding 869 units, so
--                units differ from rows by 481. Amount per row roughly doubles for
--                qty 2, suggesting amount is a LINE TOTAL (to confirm with client).
--                Three rows (qty 9, 13, 15) show amount 0; checked in A29.
SELECT
    qty,
    COUNT(*)                          AS n,
    COALESCE(SUM(amount::numeric), 0) AS amount_total
FROM raw.amazon_sales
GROUP BY qty
ORDER BY qty::int;


-- [A29] ROWS WITH QUANTITY OF 5 OR MORE
-- What I check : the status, SKU and amount of every row with qty >= 5
-- Why          : decides whether the three zero-amount rows (qty 9, 13, 15) are
--                real orders or errors that would inflate unit counts
-- Finding      : 6 rows with qty >= 5. Three Shipped rows (qty 15, 13, 9; index
--                937, 3636, 3631) have a NULL amount (not zero, as I wrote in
--                A28) and cannot be verified. Three rows (qty 8, 5, 5) have
--                amounts of INR 2,175 to 5,584 and look plausible. Decision: keep
--                all rows, flag the three NULL-amount rows, exclude them from
--                unit and AOV measures.
SELECT
    index,
    order_id,
    status,
    sku,
    qty,
    amount
FROM raw.amazon_sales
WHERE qty::int >= 5
ORDER BY qty::int DESC;


-- [A30] PRODUCT IDENTITY: SKU, STYLE, ASIN, CATEGORY
-- What I check : number of distinct values in each product column, and whether
--                any SKU appears under more than one category
-- Why          : client question 1 ranks SKUs and categories; a SKU with two
--                categories would be counted in the wrong group
-- Finding      : 7,195 SKUs, 1,377 styles, 7,190 ASINs, 9 categories. No SKU
--                belongs to more than one category (0), so category totals are safe.
--                ~5.2 SKUs per style: a SKU appears to be style + size. Product
--                ranking should therefore use style, size analysis uses size.
--                7,195 SKUs vs 7,190 ASINs (5 more SKUs than ASINs) noted as an
--                open point, not investigated.
SELECT
    COUNT(DISTINCT sku)      AS distinct_skus,
    COUNT(DISTINCT style)    AS distinct_styles,
    COUNT(DISTINCT asin)     AS distinct_asins,
    COUNT(DISTINCT category) AS distinct_categories,
    (SELECT COUNT(*)
     FROM (SELECT sku
           FROM raw.amazon_sales
           GROUP BY sku
           HAVING COUNT(DISTINCT category) > 1) AS multi_cat
    )                        AS skus_with_more_than_one_category
FROM raw.amazon_sales;


-- [A31] NULLS, BLANKS AND PLACEHOLDER VALUES IN KEY COLUMNS
-- What I check : per key column, how many values are NULL, empty/spaces only,
--                or a placeholder such as 'nan' or 'N/A'
-- Why          : cleaning treats NULL and '' differently, and a placeholder
--                would be counted as a real value (for example a state "N/A")
-- Finding      : 11 key columns checked. NULL counts reconcile with earlier audits
--                (amount 7,795; courier_status 6,872; ship_city 33; ship_state 33;
--                all others 0). No blank strings and no placeholder values
--                (nan, N/A, none, -) in any column. NULL is the only form of
--                missing data.
SELECT
    t.col                                                   AS column_name,
    COUNT(*) FILTER (WHERE t.val IS NULL)                   AS nulls,
    COUNT(*) FILTER (WHERE TRIM(t.val) = '')                AS blanks,
    COUNT(*) FILTER (WHERE LOWER(TRIM(t.val))
                     IN ('nan', 'null', 'n/a', 'na', 'none', '-')) AS placeholders
FROM raw.amazon_sales s
CROSS JOIN LATERAL (VALUES
    ('order_id',       s.order_id),
    ('order_date',     s.order_date),
    ('status',         s.status),
    ('sku',            s.sku),
    ('category',       s.category),
    ('size',           s.size),
    ('qty',            s.qty),
    ('amount',         s.amount),
    ('ship_city',      s.ship_city),
    ('ship_state',     s.ship_state),
    ('courier_status', s.courier_status)
) AS t(col, val)
GROUP BY t.col
ORDER BY t.col;


--###############################################################################











