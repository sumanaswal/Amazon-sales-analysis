/* ============================================================
   PROJECT  : UrbanThread E-commerce Sales Performance
   FILE     : 03_analysis.sql
   AUTHOR   : Suman Aswal
   DATE     : <today>
   DATABASE : PostgreSQL. Reads clean.sales only.
   PURPOSE  : Answer the client's five questions.
   RULES    : Net revenue = SUM(amount) where status_group = 'Completed'
              and amount > 0. Units = SUM(qty). Products are ranked by
              style, not SKU. March and June are partial months.
   ============================================================ */

/* QUERY INDEX
   Headline numbers : S1 value by status group, S2 headline KPIs
   Q1 Products      : S3 category, S4 style deciles, S5 top 15 styles, S6 styles without revenue,
                      S7 styles by units, S8 weak styles by category
   Q2 Regions       : S9 states, S10 cities, S10b city/state mismatch, S11 top 15 cities vs the rest
   Q3 Trends        : S12 months (superseded by S12b), S12b, S13 weeks, S13b last days,
                      S13c weeks by fulfilment
   Q4 Losses        : S14 return rate by week (superseded by S14b), S14b, S15 fulfilment,
                      S15b status by fulfilment, S16/S16b size, S17/S17b category,
                      S18 value lost by fulfilment, S19 value lost by category and size
   Q5 Stocking      : S20 units by size, S21 units by size and fulfilment
*/




-- [S1] ORDER VALUE BY STATUS GROUP
-- What I check : order lines and amount for each status group, and each group's
--                share of the total amount
-- Why          : separates net revenue (Completed) from the value of cancelled and
--                returned orders; every later number must reconcile to this table
-- Finding      : 128,968 order lines reconcile with the clean table. Order value is
--                INR 78,590,043 in total. Net revenue (Completed) = INR 69,660,658
--                (88.6%). Cancelled 6,919,284 (8.8%), Returned 1,384,559 (1.8%),
--                In progress 622,409 (0.8%), Lost/Damaged 3,133. Cancelled + Returned
--                = INR 8.30M (10.6% of order value), a minimum: 7,563 of 18,329
--                cancelled lines have no amount. 2,477 Completed lines have no or zero
--                amount and are excluded from net revenue.
SELECT
	status_group,
	COUNT(*) 								AS order_line,
	COUNT(*) FILTER(WHERE amount > 0)		AS lines_with_amount,
	COALESCE(SUM(amount),0)					AS total_amount,
	ROUND(100.0 * COALESCE(SUM(amount),0) 
		/ SUM(SUM(amount)) OVER(),2) 		AS pct_of_amount
FROM clean.sales
GROUP BY status_group
ORDER BY total_amount DESC;


-- [S2] HEADLINE KPIs
-- What I check : net revenue, completed lines, orders, units, average order value,
--                cancellation rate and return rate
-- Why          : the six numbers at the top of the dashboard and Excel summary; they
--                must tie back to S1 (net revenue = 69,660,658)
-- Finding      : Net revenue INR 69,660,658 (ties to S1). 107,577 completed lines
--                (105,100 with an amount), 97,965 orders, 105,484 units, average
--                order value INR 711.08. Cancellation rate 14.21% (18,329 of
--                128,968 lines); return rate 1.92% (2,109 of 109,686 completed +
--                returned lines). Rates are per order line. The return rate is
--                understated for late June (data ends 29 June).
SELECT
	SUM(amount) FILTER(WHERE status_group = 'Completed' AND amount > 0)			AS net_revenue,
	COUNT(*) FILTER(WHERE status_group = 'Completed')							AS completed_lines,
	COUNT(*)    FILTER (WHERE status_group = 'Completed' AND amount > 0)		AS priced_completed_lines,
	COUNT(DISTINCT order_id) 
				FILTER(WHERE status_group = 'Completed' AND amount > 0)			AS orders,
	SUM(qty) FILTER(WHERE status_group = 'Completed' AND amount > 0)			AS units_sold,
	ROUND(SUM(amount) FILTER(WHERE status_group = 'Completed' AND amount > 0)
		/ COUNT(DISTINCT order_id) 
				FILTER(WHERE status_group = 'Completed' AND amount > 0),2)		AS avg_order_value,
	ROUND(100.0 * COUNT(*) FILTER(WHERE status_group =  'Cancelled') 
		/ COUNT(*),2)															AS cancel_rate_pct,
	ROUND(100.0 * COUNT(*) FILTER(WHERE status_group =  'Returned') 
		/ COUNT(*) FILTER(WHERE status_group IN ('Completed','Returned')),2)	AS return_rate_pct
FROM clean.sales;


-- =================================== Q1: PRODUCTS ============================================

-- [S3] NET REVENUE BY CATEGORY                                   (client Q1)
-- What I check : net revenue, share of net revenue, units and orders for each category
-- Why          : shows which product groups carry the business; the shares and units
--                must reconcile to S1/S2 (69,660,658 and 105,484)
-- Finding      : 9 categories reconcile to net revenue INR 69,660,658 and 105,484
--                units. Set 49.9%, Kurta 27.2%, Western Dress 14.1% = 91.1% of net
--                revenue; Top 6.9%; the other five categories together 2.0% (INR 1.37M).
--                Set and Kurta sell almost equal units (40,783 / 40,785) but Set earns
--                INR 34.7M vs 18.9M (about INR 852 vs 464 per unit, if amount is the
--                line total, Q6). Orders add up to 99,423, more than the 97,965 total,
--                because an order can span categories. Small categories may have few
--                listings: checked at style level in S4/S5.

SELECT
	category,
	SUM(amount) AS net_revenue,
	ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER(),2) AS pct_of_net_revenue,
	SUM(qty)	AS units_sold,
	COUNT(DISTINCT order_id)	AS orders,
	RANK() OVER(ORDER BY SUM(amount) DESC) AS revenue_rank
FROM clean.sales
WHERE status_group = 'Completed' AND amount > 0
GROUP BY category
ORDER BY net_revenue DESC;

-- [S4] STYLE CONCENTRATION BY DECILE                              (client Q1)
-- What I check : sort styles by net revenue, cut them into 10 equal groups (deciles) and
--                show each group's revenue, its share and the running (cumulative) share
-- Why          : shows how much of the revenue comes from a few styles and how long the
--                low-revenue tail is; prepares the list of best and weakest styles in S5
-- Finding      : Net revenue by style decile reconciles to INR 69,660,658 (100%).
--                The top 10% of styles earn 58.3% of net revenue, the top 20% 75.8%,
--                the top 30% 85.5%. The bottom 50% of styles earn 4.7% together; the
--                bottom 10% only INR 75,314 (0.11%). Revenue is highly concentrated.
--                Low revenue may reflect new, out-of-stock or small-batch styles
--                (no listing dates or stock data), so the tail is called
--                "low-revenue", not "dead weight". Styles with no completed,
--                priced sale do not appear in this query.
WITH style_revenue AS (
	SELECT
		style,
		SUM(amount)	AS net_revenue
	FROM clean.sales
	WHERE status_group = 'Completed' AND amount > 0
	GROUP BY style
),
ranked AS (
	SELECT
		style,
		net_revenue,
		NTILE(10) OVER(ORDER BY net_revenue DESC) AS decile
	FROM style_revenue
)
SELECT
	decile,
	COUNT(*)													AS styles,
	SUM(net_revenue)											AS net_revenue,
	ROUND(100.0 * SUM(net_revenue) 
		/ SUM(SUM(net_revenue)) OVER(),2)						AS pct_of_net_revenue,
	ROUND(100.0 * SUM(SUM(net_revenue)) OVER(ORDER BY decile) 
		/ SUM(SUM(net_revenue)) OVER(),2)						AS cumulative_pct
FROM ranked
GROUP BY decile
ORDER BY decile;


-- [S5] TOP 15 STYLES BY NET REVENUE                              (client Q1)
-- What I check : the 15 highest-earning styles with category, net revenue, units, revenue
--                per unit, share and running share; also whether any style appears under
--                more than one category
-- Why          : names the styles that carry the business (client Q1); the category
--                check closes the open point from A30
-- Finding      : Top 15 styles earn INR 13,526,776 = 19.42% of net revenue (top style
--                JNE3797, Western Dress, 3.56%, 3,314 units). 9 are Set, 5 Western
--                Dress, 1 Kurta. Revenue per unit ranges INR 409 (JNE3405) to INR 1,472
--                (SET278), assuming amount is the line total (Q6). Each of the 15
--                styles belongs to exactly one category (all styles checked in S6).
--                The top 10% of styles (about 135) earn 58.3% (S4), so revenue rests
--                on a broad top group, not on a few heroes.
SELECT
    style,
    MIN(category)                                                AS category,
    COUNT(DISTINCT category)                                     AS categories_for_style,
    SUM(amount)                                                  AS net_revenue,
    SUM(qty)                                                     AS units_sold,
    ROUND(SUM(amount) / NULLIF(SUM(qty), 0), 0)                  AS revenue_per_unit,
    ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER (), 2)     AS pct_of_net_revenue,
    ROUND(100.0 * SUM(SUM(amount)) OVER (ORDER BY SUM(amount) DESC, style)
          / SUM(SUM(amount)) OVER (), 2)                         AS cumulative_pct
FROM clean.sales
WHERE status_group = 'Completed'
  AND amount > 0
GROUP BY style
ORDER BY net_revenue DESC
LIMIT 15;


-- [S6] STYLES WITH NO NET REVENUE AND CATEGORY CHECK              (client Q1)
-- What I check : how many styles exist, how many earned net revenue, how many earned none,
--                the order lines and cancelled/returned value inside the no-revenue styles,
--                and whether any style appears in more than one category
-- Why          : gives Priya a defensible count of "dead weight" styles (no completed
--                sale at all) and closes the style-category check from A30 for every style
-- Finding      : 1,377 styles in clean.sales (same as raw, A30). 0 styles appear in more
--                than one category (closes the A30 style check for every style).
--                1,368 styles earned net revenue, 9 did not (0.65%): they hold 10 order
--                lines and INR 2,292 of cancelled/returned value. "Dead weight" in the
--                strict sense (no completed, priced sale in 91 days) is therefore
--                marginal; the real tail is the low-revenue styles from S4 (bottom 684
--                styles earn 4.7% of net revenue).
WITH style_summary AS (
	SELECT
		style,
		COUNT(DISTINCT category)										AS categories,
		COUNT(*)														AS order_lines,
		COALESCE(SUM(amount) 
			FILTER(WHERE status_group = 'Completed' AND amount > 0),0)	AS net_revenue,
		COALESCE(SUM(amount) 
			FILTER(WHERE status_group IN ('Cancelled','Returned')),0) 	AS cancelled_returned_value
	FROM clean.sales
	GROUP BY style
)
SELECT
	COUNT(*)			AS total_styles,
	COUNT(*) FILTER(WHERE categories > 1)										AS styles_in_more_than_one_categories,
	COUNT(*) FILTER(WHERE net_revenue > 0)										AS styles_with_net_revenue,
	COUNT(*) FILTER(WHERE net_revenue <= 0)										AS styles_without_net_revenue,
	COALESCE(SUM(order_lines) FILTER(WHERE net_revenue <= 0),0)					AS lines_in_those_styles,
	COALESCE(SUM(cancelled_returned_value) FILTER(WHERE net_revenue <= 0), 0)	AS cancelled_returned_value_in_those_styles
FROM style_summary;

-- [S7] STYLES BY UNITS SOLD                                      (client Q1)
-- What I check : group the 1,368 styles that earned net revenue into bands by units sold,
--                with each band's number of styles, net revenue and share of net revenue
-- Why          : gives Priya a plain-English definition of the weak tail (e.g. styles
--                selling under 20 units in 91 days); bands must reconcile to 1,368 styles
--                and INR 69,660,658
-- Finding      : 1,368 styles with net revenue reconcile to INR 69,660,658. 557 styles
--                (40.7%) sold fewer than 20 units in 91 days and earned INR 1.99M
--                (2.85% of net revenue): 259 under 5 units (0.40%), 298 with 5-19 units
--                (2.45%). 267 styles (19.5%) with 100+ units earn 73.8%; the 30 styles with
--                500+ units earn 25.9%. Units count completed, priced lines only; no listing
--                dates or stock data, so "weak" does not mean "failing".
WITH style_sales AS (
SELECT
	style,
	SUM(amount)	AS net_revenue,
	SUM(qty)	AS units_sold
FROM clean.sales
WHERE status_group = 'Completed'
	AND amount > 0
GROUP BY style
)
SELECT
	CASE WHEN units_sold < 5 THEN '1. under 5 units'
		WHEN units_sold < 20 THEN '2. 5 to 19 units'
		WHEN units_sold < 100 THEN '3. 20 to 99 units'
		WHEN units_sold < 500 THEN '4. 100 to 499 units'
		ELSE						'5. 500 units or more'
	END															AS unit_band,
	COUNT(*)													AS styles,
	SUM(net_revenue)											AS net_revenue,
	ROUND(100.0 * SUM(net_revenue) 
		/ SUM(SUM(net_revenue)) OVER(),2)						AS pct_of_net_revenue
FROM style_sales
GROUP BY unit_band
ORDER BY unit_band;

-- [S8] WEAK STYLES BY CATEGORY                                   (client Q1)
-- What I check : for each category, how many styles earned net revenue, how many sold fewer
--                than 20 units, their share of the category's styles, and the net revenue
--                they earned
-- Why          : shows where the catalogue is cluttered with slow styles; totals must tie
--                to S7 (1,368 styles, 557 weak styles) and S3 (INR 69,660,658)
-- Finding      : Totals reconcile: 1,368 styles, 557 weak styles (under 20 units), net
--                revenue INR 69,660,658, weak-style revenue INR 1,985,835. Kurta has the
--                most weak styles (188 of 532, 35%; INR 616,066 = 3.3% of Kurta revenue),
--                then Set (122 of 423) and Top (51 of 142). In Saree, Blouse, Bottom,
--                Ethnic Dress and Dupatta, 178 of 200 styles (89%) are weak. Western Dress
--                has only 18 weak styles of 71 and the highest revenue per style (about
--                INR 138,400). Saree averages about 2 units per style.
WITH style_sales AS (
    SELECT
        style,
        MIN(category) AS category,
        SUM(amount)   AS net_revenue,
        SUM(qty)      AS units_sold
    FROM clean.sales
    WHERE status_group = 'Completed'
      AND amount > 0
    GROUP BY style
)
SELECT
    category,
    COUNT(*)                                                      AS styles,
    COUNT(*) FILTER (WHERE units_sold < 20)                       AS weak_styles,
    ROUND(100.0 * COUNT(*) FILTER (WHERE units_sold < 20)
          / COUNT(*), 1)                                          AS pct_weak_styles,
    SUM(net_revenue)                                              AS net_revenue,
    COALESCE(SUM(net_revenue) FILTER (WHERE units_sold < 20), 0)  AS weak_styles_revenue,
	ROUND(100.0 * COALESCE(SUM(net_revenue) FILTER (WHERE units_sold < 20), 0)
		/ SUM(net_revenue),2)										AS pct_weak_net_revenue
FROM style_sales
GROUP BY category
ORDER BY styles DESC;


-- =================================== Q2: REGIONS ============================================


-- [S9] TOP 15 STATES: NET REVENUE, CANCELLATION AND RETURN RATES   (client Q2)
-- What I check : net revenue, its share, order lines, cancellation rate (cancelled lines /
--                all lines) and return rate (returned lines / completed + returned lines)
--                for the 15 states with the highest net revenue
-- Why          : shows where the money comes from and where cancellations and returns hurt;
--                shares are calculated against all states, rates use the S2 definitions
-- Finding      : Top 15 states earn INR 62,848,588 = 90.2% of net revenue (116,461 of
--                128,968 lines). Maharashtra 17.2% and Karnataka 13.5% lead (30.7% together);
--                top 6 states 62.1%; the five southern states 39.3%. Cancellation rate
--                averages 14.21%; Kerala is highest at 17.8% (6,584 lines), Haryana lowest
--                at 12.8%. Return rate averages 1.92%; highest in Bihar 3.7%, Odisha 3.2%,
--                Uttar Pradesh 2.7% (small bases in Bihar and Odisha, about 2,100 lines
--                each). Line counts tie to A14 and the 7 removed rows (e.g. Delhi 7,048
--                includes the 81 New Delhi rows). Causes are not in the data.
SELECT
    ship_state,
    SUM(amount) FILTER 
		(WHERE status_group = 'Completed' AND amount > 0)           AS net_revenue,
    ROUND(100.0 * SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)
          / SUM(SUM(amount) 
		  FILTER (WHERE status_group = 'Completed' AND amount > 0)) OVER (), 1)		AS pct_of_net_revenue,
    COUNT(*)                                                                      	AS order_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Cancelled')
          / COUNT(*), 1)                                                           AS cancel_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE status_group IN ('Completed', 'Returned')), 0), 1)
                                                                                   AS return_rate_pct
FROM clean.sales
GROUP BY ship_state
ORDER BY net_revenue DESC NULLS LAST
LIMIT 15;


-- [S10] TOP 15 CITIES: NET REVENUE, CANCELLATION AND RETURN RATES   (client Q2)
-- What I check : net revenue, share, order lines, cancellation and return rates for the 15
--                cities with the highest net revenue, plus the number of different states
--                seen under each city name
-- Why          : shows which cities drive sales (client Q2); shares are against ALL cities;
--                states_seen warns if a city name covers more than one state
-- Finding      : Top 15 cities earn INR 34,694,738 = 49.8% of net revenue (63,312 lines);
--                the other 50.2% is spread across thousands of towns and free-text rows
--                ("Other"). Bengaluru leads with INR 7.40M (10.6%; 78% of Karnataka), then
--                Hyderabad 7.1%, Mumbai 5.7%, New Delhi 5.4%, Chennai 4.7%, Pune 3.7%. Mumbai,
--                Pune, Thane and Navi Mumbai hold 70% of Maharashtra. Cancellation rates range
--                11.2% (Gurugram) to 14.9% (Lucknow); 13 of 15 are below the 14.21% average.
--                Return rates highest in Lucknow 2.8% and Ghaziabad 2.7%. Hyderabad and New
--                Delhi each appear under 2 states (see S10b). 54 typo rows (C3e) were not merged
--                (0.04%).
SELECT
    ship_city,
    COUNT(DISTINCT ship_state)                                                     AS states_seen,
    SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)           AS net_revenue,
    ROUND(100.0 * SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)
          / SUM(SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)) OVER (), 1)
                                                                                   AS pct_of_net_revenue,
    COUNT(*)                                                                       AS order_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Cancelled')
          / COUNT(*), 1)                                                           AS cancel_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE status_group IN ('Completed', 'Returned')), 0), 1)
                                                                                   AS return_rate_pct
FROM clean.sales
GROUP BY ship_city
ORDER BY net_revenue DESC NULLS LAST
LIMIT 15;


-- [S10b] STATES BEHIND HYDERABAD AND NEW DELHI                    (client Q2)
-- What I check : each state seen under the city names Hyderabad and New Delhi, with order
--                lines and net revenue
-- Why          : S10 showed 2 states for each; decides whether the state ranking (S9) needs a
--                note or the city view needs a fix
-- Finding      : Hyderabad appears under Telangana (9,116 lines, INR 4,939,574) and Andhra
--                Pradesh (33 lines, INR 19,757); New Delhi under Delhi (6,747 lines) and Uttar
--                Pradesh (1 line, INR 599). Totals tie to S10. Customers type city and state
--                separately and they are not cross-checked. Effect: Telangana understated
--                about 0.3%, Andhra Pradesh overstated about 0.7%, no rank change. Not fixed.
SELECT
    ship_city,
    ship_state,
    COUNT(*)                                                                 AS order_lines,
    SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)     AS net_revenue
FROM clean.sales
WHERE ship_city IN ('Hyderabad', 'New Delhi')
GROUP BY ship_city, ship_state
ORDER BY ship_city, order_lines DESC;

-- [S11] CANCELLATION RATE: TOP 15 CITIES VS ALL OTHER CITIES      (client Q2)
-- What I check : order lines, cancelled lines, cancellation rate and net revenue for the 15
--                biggest cities versus all other cities (including "Unknown")
-- Why          : tests whether cancellations hurt more outside the big cities; totals must tie to
--                S1/S2 (128,968 lines, 18,329 cancelled lines, INR 69,660,658)
-- Finding      : Totals reconcile: 128,968 lines, 18,329 cancelled, INR 69,660,658. The 15
--                biggest cities (by net revenue) cancel 12.80% of lines (8,104 of 63,312); all
--                other cities (6,995, incl. Unknown) cancel 15.57% (10,225 of 65,656), about 22%
--                more per line. Net revenue per line is similar (INR 548 vs 533). At the big-city
--                rate, about 1,800 fewer cancelled lines (roughly 10% of all cancellations).
--                Free-text address rows alone cannot explain the gap (bound: 50% cancelled
--                gives 14.5%). Causes are not in the data.
WITH city_totals AS (
    SELECT
        ship_city,
        COUNT(*)                                                                 AS order_lines,
        COUNT(*) FILTER (WHERE status_group = 'Cancelled')                       AS cancelled_lines,
        SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)     AS net_revenue
    FROM clean.sales
    GROUP BY ship_city
),
ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY net_revenue DESC NULLS LAST) AS city_rank
    FROM city_totals
)
SELECT
    CASE WHEN city_rank <= 15 THEN 'Top 15 cities' ELSE 'All other cities' END  AS city_group,
    COUNT(*)                                                                      AS cities,
    SUM(order_lines)                                                              AS order_lines,
    SUM(cancelled_lines)                                                          AS cancelled_lines,
    ROUND(100.0 * SUM(cancelled_lines) / SUM(order_lines), 2)                     AS cancel_rate_pct,
    SUM(net_revenue)                                                              AS net_revenue
FROM ranked
GROUP BY city_group
ORDER BY city_group DESC;


-- =================================== Q3: TRENDS ============================================


-- [S12] MONTHLY NET REVENUE AND REVENUE PER DAY                  (client Q3)
-- What I check : per calendar month, days of data, net revenue, net revenue per day, order
--                lines and cancellation rate
-- Why          : March (1 day) and June (29 days) are partial months, so only revenue per day
--                compares them fairly; totals must tie to S1 (91 days, INR 69,660,658)
-- Finding      : Totals reconcile: 91 days, INR 69,660,658, 128,968 lines. Net revenue per day:
--                April INR 855,628, May 756,913 (-11.5%), June 704,598 (-6.9%); -17.6% April to
--                June. Order lines per day fell 17.1% from April to May while revenue per line
--                rose 6.7% (INR 523 to 558), so the decline is in volume. Cancellation rate is
--                stable at 14.0-14.5% in full months. March (1 day, 171 lines) is excluded from
--                comparisons. Causes are not in the data; early May shows a spike (A12b).
-- Superseded by S12b
SELECT
    DATE_TRUNC('month', order_date)::date                                          AS order_month,
    COUNT(DISTINCT order_date)                                                     AS days_in_data,
    SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)           AS net_revenue,
    ROUND(SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)
          / COUNT(DISTINCT order_date), 0)                                         AS net_revenue_per_day,
    COUNT(*)                                                                       AS order_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Cancelled')
          / COUNT(*), 1)                                                           AS cancel_rate_pct
FROM clean.sales
GROUP BY order_month
ORDER BY order_month;


-- [S13] WEEKLY NET REVENUE AND WEEK-ON-WEEK CHANGE                (client Q3)
-- What I check : per week (Monday start), days of data, net revenue, net revenue per day, the
--                change in revenue per day against the previous week, and order lines
-- Why          : shows spikes and dips that the monthly view hides; the first week (4 days) and
--                the last week (3 days) are partial, so revenue per day is used
-- Finding      : Totals reconcile: 14 weeks (4 + 12 x 7 + 3 days = 91), INR 69,660,658, 128,968
--                lines. Revenue per day peaks in the week of 2 May (INR 926,131), falls 27.8% in the
--                week of 9 May (INR 669,020; order lines 11,934 to 8,519) and stays low, recovers to
--                INR 827,811 by 6 June, then falls to INR 643,885 (week of 20 June, lowest full
--                week). The +32.9% in the week of 4 April is an artifact of the partial 31 March
--                (about +3.5% without it). The last week (3 days, -38.6%) is partial and may be
--                understated by In progress orders (checked in S13b). Causes are not in the data.
WITH weekly AS (
    SELECT
        DATE_TRUNC('week', order_date)::date                                          AS week_start,
        COUNT(DISTINCT order_date)                                                    AS days_in_data,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0), 0)
                                                                                      AS net_revenue,
        COUNT(*)                                                                      AS order_lines
    FROM clean.sales
    GROUP BY week_start
)
SELECT
    week_start,
    days_in_data,
    net_revenue,
    ROUND(net_revenue / days_in_data, 0)                                              AS net_revenue_per_day,
    ROUND(100.0 * (net_revenue / days_in_data
                   - LAG(net_revenue / days_in_data) OVER (ORDER BY week_start))
          / NULLIF(LAG(net_revenue / days_in_data) OVER (ORDER BY week_start), 0), 1) AS change_vs_prev_week_pct,
    order_lines
FROM weekly
ORDER BY week_start;

-- [S13b] STATUS MIX OF THE LAST 14 DAYS                           (client Q3)
-- What I check : for each day from 16 June, order lines by status group, share of In progress
--                lines and net revenue
-- Why          : S13 showed the last week (3 days) with revenue per day far below its order lines;
--                if recent orders are still "In progress" they are not net revenue yet, which
--                would understate the end of the period
-- Finding      : 14 days (16-29 June). In progress share is 0.0-0.5% until 25 June, then 1.5% (26),
--                4.5% (27), 31.7% (28) and 69.0% (29). 929 of the 947 In progress lines (98%) are
--                from these 14 days and 887 (94%) from 27-29 June, so recent orders are not yet
--                shipped and are not net revenue yet. 29 June has only 658 lines (partial day) and
--                a 4.7% cancellation rate (about 14% normally). The -38.6% in the last week of S13
--                is an artifact of 28-29 June; 27 June alone earned INR 627,000 (-2.6% vs the
--                previous week's average).
SELECT
    order_date,
    COUNT(*)                                                                    AS order_lines,
    COUNT(*) FILTER (WHERE status_group = 'Completed')                          AS completed,
    COUNT(*) FILTER (WHERE status_group = 'In progress')                        AS in_progress,
    COUNT(*) FILTER (WHERE status_group = 'Cancelled')                          AS cancelled,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'In progress')
          / COUNT(*), 1)                                                        AS in_progress_pct,
    SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)        AS net_revenue
FROM clean.sales
WHERE order_date >= DATE '2022-06-16'
GROUP BY order_date
ORDER BY order_date;

-- [S12b] MONTHLY NET REVENUE PER DAY, WITHOUT THE INCOMPLETE END DAYS   (client Q3)
-- What I check : S12 repeated for 1 April to 27 June (28-29 June and 31 March excluded)
-- Why          : S13b showed 28-29 June are mostly In progress (31.7%, 69.0%), so their net revenue
--                is understated and pulls June down; 31 March is a partial first day
-- Finding      : 1 April to 27 June (88 days). Net revenue per day: April INR 855,628, May 756,913
--                (-11.5%), June 736,054 (-2.8% vs May, -14.0% vs April). April and May equal S12.
--                Removing 28-29 June (INR 559,870 of Completed revenue, understated by In progress
--                orders, S13b) shows June is flatter than S12 suggested (-2.8% vs -6.9% vs May).
SELECT
    DATE_TRUNC('month', order_date)::date                                          AS order_month,
    COUNT(DISTINCT order_date)                                                     AS days_in_data,
    SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)           AS net_revenue,
    ROUND(SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0)
          / COUNT(DISTINCT order_date), 0)                                         AS net_revenue_per_day
FROM clean.sales
WHERE order_date BETWEEN DATE '2022-04-01' AND DATE '2022-06-27'
GROUP BY order_month
ORDER BY order_month;


-- =================================== Q4: LOSSES ============================================

-- [S14] CANCELLATION AND RETURN RATES BY ORDER WEEK               (client Q4)
-- What I check : for each full week from 4 April to 26 June, order lines, cancellation rate and
--                return rate (returned / completed + returned)
-- Why          : returns take time to appear; if recent weeks show lower return rates, the latest
--                orders have not had time to be returned and must be left out of the Q4 comparisons
--                (28-29 June are excluded: mostly In progress, S13b)
-- Finding      : 12 full weeks (4 Apr-26 Jun), 121,102 lines; 2,053 returned lines (97% of 2,109).
--                Cancellation rate 12.8-15.6% every week, no lag visible. Return rate about 2.2%
--                in the 7 weeks 4 Apr-22 May (1.24-3.03%) and about 1.6% in the 5 weeks from 23
--                May (1.39-1.91%): either returns are recorded late or they fell; the data cannot
--                tell. Decision for Q4: cancellation rates use 4 Apr-26 Jun; return rates use
--                4 Apr-22 May. Week-to-week return rates differ beyond noise (1.24% in the week of
--                2 May vs 3.03% the week after); cause unknown.
-- Superseded by S14b: the fall in the blended return rate is a Merchant-share (mix) effect.
SELECT
    DATE_TRUNC('week', order_date)::date                                           AS week_start,
    COUNT(*)                                                                       AS order_lines,
    COUNT(*) FILTER (WHERE status_group = 'Returned')                              AS returned_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Cancelled')
          / COUNT(*), 1)                                                           AS cancel_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE status_group IN ('Completed', 'Returned')), 0), 2)
                                                                                   AS return_rate_pct
FROM clean.sales
WHERE order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26'
GROUP BY week_start
ORDER BY week_start;

-- [S15] CANCELLATION AND RETURN RATES BY FULFILMENT TYPE           (client Q4)
-- What I check : per fulfilment type, order lines and cancellation rate (4 Apr-26 Jun), and
--                shipped lines, returned lines and return rate (4 Apr-22 May)
-- Why          : tests whether the fulfilment method relates to losses; the two windows follow S14
--                (returns need older orders; no lag seen in cancellations)
-- Finding      : 121,102 lines (4 Apr-26 Jun) and 1,409 returned lines (4 Apr-22 May) reconcile to
--                S14. Amazon: 83,814 lines, cancellation rate 12.8%, 43,034 shipped lines, 0
--                returns. Merchant (Easy Ship): 37,288 lines, cancellation rate 17.5%, 21,053
--                shipped lines, 1,409 returns = 6.69%. All recorded returns are Merchant orders
--                (status "Returned to Seller"); Amazon shows none, which may be a recording
--                difference (checked in S15b). The 1.92% return rate (S2) mixes both groups and
--                understates the rate for Merchant orders.
WITH scoped AS (
    SELECT
        *,
        (order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26') AS in_cancel_window,
        (order_date BETWEEN DATE '2022-04-04' AND DATE '2022-05-22') AS in_return_window
    FROM clean.sales
)
SELECT
    fulfilment,
    COUNT(*) FILTER (WHERE in_cancel_window)                                         AS order_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE in_cancel_window AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE in_cancel_window), 0), 1)                  AS cancel_rate_pct,
    COUNT(*) FILTER (WHERE in_return_window
                       AND status_group IN ('Completed', 'Returned'))                AS shipped_lines_return_window,
    COUNT(*) FILTER (WHERE in_return_window AND status_group = 'Returned')           AS returned_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE in_return_window AND status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE in_return_window
                       AND status_group IN ('Completed', 'Returned')), 0), 2)        AS return_rate_pct
FROM scoped
GROUP BY fulfilment
ORDER BY fulfilment;


-- [S15b] STATUS BY FULFILMENT TYPE                                (client Q4)
-- What I check : for each of the 13 raw statuses, lines under Amazon and under Merchant
-- Why          : S15 showed returns only on Merchant orders; this shows whether Amazon-fulfilled
--                orders ever carry a return, delivered or lost status at all
-- Finding      : 13 statuses; Amazon lines 89,691 and Merchant lines 39,277 reconcile (the 7
--                removed rows were Amazon). Amazon orders only ever have the statuses Shipped
--                (77,800), Cancelled (11,468), Pending (415) and Shipping (8); delivered,
--                returned, lost and damaged statuses exist only for Merchant orders, which have
--                no plain Shipped status. Amazon returns are therefore not recorded, and Amazon
--                Completed (72% of Completed lines) means "shipped", not "delivered". The
--                Merchant return rate is about 6.7% early and about 6.5% later (derived); the
--                fall in the blended rate in S14 is mainly a drop in Merchant share.
SELECT
    status,
    status_group,
    COUNT(*) FILTER (WHERE fulfilment = 'Amazon')   AS amazon_lines,
    COUNT(*) FILTER (WHERE fulfilment = 'Merchant') AS merchant_lines
FROM clean.sales
GROUP BY status, status_group
ORDER BY status_group, status;


-- [S14b] MERCHANT-ONLY RETURN RATE AND MERCHANT SHARE BY ORDER WEEK   (client Q4)
-- What I check : for each full week 4 Apr-26 Jun, Merchant shipped lines, Merchant returned lines,
--                the Merchant return rate, and Merchant's share of all shipped lines
-- Why          : S15b showed returns exist only for Merchant orders, so the S14 fall in return
--                rate may be a mix effect (fewer Merchant orders) rather than late recording;
--                if the Merchant return rate stays flat, no return lag is visible
-- Finding      : 12 weeks reconcile to S14/S15 (2,053 returns; 1,409 on 21,053 Merchant shipped
--                lines in the first seven weeks). Merchant return rate is 6.75-7.37% in ten of
--                twelve weeks (6.78% for 4 Apr-19 Jun: 1,956 of 28,838); lower in the week of 2
--                May (4.83%, cause unknown) and the last week of 20 Jun (5.07%, orders only 3-9
--                days old, possibly incomplete). Merchant share of shipped lines ranges 21.6-42.0%
--                (about 33% in the first seven weeks, about 24% in the last five): the S14 fall in
--                the blended rate (about 2.2% to 1.6%) is a mix effect, not late recording.
--                Return window for Q4: 4 Apr-19 Jun, Merchant only.
SELECT
    DATE_TRUNC('week', order_date)::date                                           AS week_start,
    COUNT(*) FILTER (WHERE fulfilment = 'Merchant'
                       AND status_group IN ('Completed', 'Returned'))              AS merchant_shipped_lines,
    COUNT(*) FILTER (WHERE fulfilment = 'Merchant'
                       AND status_group = 'Returned')                              AS merchant_returned_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fulfilment = 'Merchant' AND status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE fulfilment = 'Merchant'
                       AND status_group IN ('Completed', 'Returned')), 0), 2)     AS merchant_return_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fulfilment = 'Merchant'
                       AND status_group IN ('Completed', 'Returned'))
          / NULLIF(COUNT(*) FILTER (WHERE status_group IN ('Completed', 'Returned')), 0), 1)
                                                                                   AS merchant_share_of_shipped_pct
FROM clean.sales
WHERE order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26'
GROUP BY week_start
ORDER BY week_start;


-- [S16] CANCELLATION RATE BY SIZE AND FULFILMENT TYPE              (client Q4)
-- What I check : per size, order lines and cancellation rate overall, for Amazon and for Merchant
--                (orders of 4 Apr-26 Jun)
-- Why          : tests whether size relates to cancellations; fulfilment is shown separately
--                because Merchant cancels more (S15) and could distort a size comparison
-- Finding      : 11 sizes reconcile: 121,102 lines (Amazon 83,814, Merchant 37,288). Cancellation
--                rate falls almost steadily from 16.6% (XS) to 12.7% (3XL): XS 16.6, S 15.2, M 14.8,
--                L 14.2, XL 13.8, XXL 13.4, 3XL 12.7; 4XL-6XL 9.3-11.7% on 368-659 lines each; Free
--                13.2% on 356. The slope appears inside both fulfilment types (Amazon 15.3% to 11.0%,
--                Merchant 20.4% to 16.2%, XS to 3XL), and Merchant cancels more than Amazon in all 11
--                sizes (3.7-5.7 points in the seven main sizes). Merchant's share of lines is 25-32%
--                in those sizes, so the mix does not explain the slope. Size may stand in for
--                category (checked next). Causes are not in the data.
WITH scoped AS (
    SELECT *
    FROM clean.sales
    WHERE order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26'
)
SELECT
    size,
    COUNT(*)                                                                       AS order_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Cancelled')
          / COUNT(*), 1)                                                           AS cancel_rate_pct,
    COUNT(*) FILTER (WHERE fulfilment = 'Amazon')                                  AS amazon_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fulfilment = 'Amazon' AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE fulfilment = 'Amazon'), 0), 1)           AS amazon_cancel_pct,
    COUNT(*) FILTER (WHERE fulfilment = 'Merchant')                                AS merchant_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fulfilment = 'Merchant' AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE fulfilment = 'Merchant'), 0), 1)         AS merchant_cancel_pct
FROM scoped
GROUP BY size
ORDER BY CASE size
             WHEN 'XS'  THEN 1  WHEN 'S'   THEN 2  WHEN 'M'   THEN 3
             WHEN 'L'   THEN 4  WHEN 'XL'  THEN 5  WHEN 'XXL' THEN 6
             WHEN '3XL' THEN 7  WHEN '4XL' THEN 8  WHEN '5XL' THEN 9
             WHEN '6XL' THEN 10 ELSE 11 END;



-- [S16b] MERCHANT RETURN RATE BY SIZE                              (client Q4)
-- What I check : per size, Merchant shipped lines, returned lines and return rate for orders of
--                4 Apr-19 Jun
-- Why          : tests whether size relates to returns; Merchant only, because Amazon returns are
--                not recorded (S15b); window from S14b
-- Finding      : 11 sizes reconcile: Merchant shipped lines 28,838 and returned lines 1,956 (6.78%),
--                orders of 4 Apr-19 Jun. Return rate falls from 8.26% (XS, 1,962 lines) to 6.09%
--                (3XL, 3,595 lines): XS 8.26, S 7.58, M 7.11, L 6.43, XL 6.43, XXL 6.53, 3XL 6.09.
--                XS+S 7.82%, M 7.11%, L-3XL 6.39%. The XS vs 3XL gap (2.2 points) is about three
--                standard errors. 4XL, 5XL, 6XL and Free have 61-140 shipped lines each (346 in
--                total, 19 returns = 5.5%) and are not quoted. Same direction as cancellations
--                (S16). Size may stand in for category (S17). Cause unknown.
SELECT
    size,
    COUNT(*) FILTER (WHERE status_group IN ('Completed', 'Returned'))               AS merchant_shipped_lines,
    COUNT(*) FILTER (WHERE status_group = 'Returned')                               AS merchant_returned_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE status_group IN ('Completed', 'Returned')), 0), 2)
                                                                                    AS merchant_return_rate_pct
FROM clean.sales
WHERE fulfilment = 'Merchant'
  AND order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-19'
GROUP BY size
ORDER BY CASE size
             WHEN 'XS'  THEN 1  WHEN 'S'   THEN 2  WHEN 'M'   THEN 3
             WHEN 'L'   THEN 4  WHEN 'XL'  THEN 5  WHEN 'XXL' THEN 6
             WHEN '3XL' THEN 7  WHEN '4XL' THEN 8  WHEN '5XL' THEN 9
             WHEN '6XL' THEN 10 ELSE 11 END;


-- [S17] CANCELLATION AND MERCHANT RETURN RATE BY CATEGORY          (client Q4)
-- What I check : per category, order lines, cancellation rate (4 Apr-26 Jun), Merchant share of
--                lines, Merchant shipped lines and Merchant return rate (4 Apr-19 Jun)
-- Why          : tests whether category relates to losses; Merchant share is shown because Merchant
--                cancels more (S15) and a category with more Merchant orders would look worse for
--                that reason alone; also checks whether the size slope (S16, S16b) is a category effect
-- Finding      : 9 categories reconcile: 121,102 lines, 28,838 Merchant shipped lines. Cancellation
--                rate (4 Apr-26 Jun): Set 14.6% (46,979 lines) and Kurta 14.6% (46,902) highest,
--                Western Dress 13.7%, Top 12.0% (9,956); small categories 12.7-13.6%; Dupatta (3 lines)
--                not quoted. Merchant share 20.8% (Saree) to 45.1% (Western Dress) vs 30.8% overall;
--                Western Dress and Top cancel about 1.2 and 1.9 points below what their Merchant mix
--                suggests (rough check using the S15 rates). Merchant return rate (4 Apr-19 Jun): Set
--                7.22% (10,753 lines), Kurta 6.77%, Top 6.46%, Western Dress 6.12%; the five small
--                categories have under 300 Merchant shipped lines each and are not quoted. Category
--                spread (2.6 points) is smaller than the size spread (S16). Cause unknown.
WITH scoped AS (
    SELECT
        *,
        (order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26') AS in_cancel_window,
        (order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-19') AS in_return_window
    FROM clean.sales
)
SELECT
    category,
    COUNT(*) FILTER (WHERE in_cancel_window)                                         AS order_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE in_cancel_window AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE in_cancel_window), 0), 1)                  AS cancel_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE in_cancel_window AND fulfilment = 'Merchant')
          / NULLIF(COUNT(*) FILTER (WHERE in_cancel_window), 0), 1)                  AS merchant_share_pct,
    COUNT(*) FILTER (WHERE in_return_window AND fulfilment = 'Merchant'
                       AND status_group IN ('Completed', 'Returned'))                AS merchant_shipped_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE in_return_window AND fulfilment = 'Merchant'
                                     AND status_group = 'Returned')
          / NULLIF(COUNT(*) FILTER (WHERE in_return_window AND fulfilment = 'Merchant'
                                      AND status_group IN ('Completed', 'Returned')), 0), 2)
                                                                                     AS merchant_return_rate_pct
FROM scoped
GROUP BY category
ORDER BY order_lines DESC;


-- [S17b] CANCELLATION RATE BY SIZE INSIDE SET, KURTA AND WESTERN DRESS   (client Q4)
-- What I check : for each of the three biggest categories, order lines and cancellation rate in every
--                size from XS to 3XL (orders of 4 Apr-26 Jun)
-- Why          : tests whether the size slope in S16 also appears inside each category, or is only an
--                effect of categories having different size mixes
-- Finding      : 7 sizes reconcile: Set 46,826, Kurta 45,546 and Western Dress 14,693 lines (107,065
--                in total; sizes 4XL-6XL and Free are left out: 153 Set and 1,356 Kurta lines). The
--                cancellation rate falls with size inside all three categories: Set 17.1% (XS) to
--                13.3% (3XL), Kurta 17.0% to 13.0%, Western Dress 15.1% to 11.6%. The gaps are about
--                5.5, 4.8 and 2.8 standard errors (Western Dress is noisier: 1,365 lines in XS). So
--                the S16 slope is not an effect of category size mix. Cause unknown (Q18).
SELECT
    size,
    COUNT(*) FILTER (WHERE category = 'Set')                                         AS set_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE category = 'Set' AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE category = 'Set'), 0), 1)                  AS set_cancel_pct,
    COUNT(*) FILTER (WHERE category = 'Kurta')                                       AS kurta_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE category = 'Kurta' AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE category = 'Kurta'), 0), 1)                AS kurta_cancel_pct,
    COUNT(*) FILTER (WHERE category = 'Western Dress')                               AS dress_lines,
    ROUND(100.0 * COUNT(*) FILTER (WHERE category = 'Western Dress' AND status_group = 'Cancelled')
          / NULLIF(COUNT(*) FILTER (WHERE category = 'Western Dress'), 0), 1)        AS dress_cancel_pct
FROM clean.sales
WHERE order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26'
  AND category IN ('Set', 'Kurta', 'Western Dress')
  AND size IN ('XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL')
GROUP BY size
ORDER BY CASE size
             WHEN 'XS'  THEN 1 WHEN 'S'   THEN 2 WHEN 'M'   THEN 3
             WHEN 'L'   THEN 4 WHEN 'XL'  THEN 5 WHEN 'XXL' THEN 6
             WHEN '3XL' THEN 7 END;


-- [S18] VALUE LOST TO CANCELLATIONS AND RETURNS BY FULFILMENT TYPE    (client Q4)
-- What I check : per fulfilment type, net revenue, cancelled lines and cancelled value (priced
--                lines only), cancelled lines without an amount, returned lines and returned value,
--                and the share of total order value that is cancelled or returned
-- Why          : puts a rupee figure on the loss for each fulfilment type; totals must tie to S1
--                (net INR 69,660,658; cancelled 6,919,284; returned 1,384,559; 18,329 cancelled
--                lines, 7,563 of them without amount; 2,109 returned lines)
-- Finding      : Totals reconcile to S1: net revenue INR 69,660,658; cancelled value 6,919,284 on
--                18,329 lines (7,563 without amount); returned 1,384,559 on 2,109 lines. Amazon: net
--                50,321,620, cancelled value 3,729,112 (11,468 lines, 5,838 without amount), no returns
--                recorded, lost 6.9% of order value. Merchant: net 19,339,038, cancelled value 3,190,172
--                (6,861 lines, 1,725 without amount), returned 1,384,559, lost 18.8%. Merchant is 27.8%
--                of net revenue but 55.1% of lost value (INR 4.57M of 8.30M). 77% of cancelled lines
--                without amount are Amazon, and returns exist only for Merchant, so 6.9% vs 18.8% is not
--                like for like: cancelled value on priced lines is 6.9% vs 13.1% of order value; valuing
--                unpriced lines at the average gives about 13.1% vs 16.8% (illustration). Cancelled value
--                is a minimum.
WITH by_type AS (
    SELECT
        fulfilment,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0), 0) AS net_revenue,
        COUNT(*) FILTER (WHERE status_group = 'Cancelled')                                AS cancelled_lines,
        COUNT(*) FILTER (WHERE status_group = 'Cancelled'
                           AND (amount IS NULL OR amount <= 0))                           AS cancelled_lines_no_amount,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Cancelled'), 0)                AS cancelled_value,
        COUNT(*) FILTER (WHERE status_group = 'Returned')                                 AS returned_lines,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Returned'), 0)                 AS returned_value,
        COALESCE(SUM(amount), 0)                                                          AS total_order_value
    FROM clean.sales
    GROUP BY fulfilment
)
SELECT
    fulfilment,
    net_revenue,
    cancelled_lines,
    cancelled_lines_no_amount,
    cancelled_value,
    returned_lines,
    returned_value,
    ROUND(100.0 * (cancelled_value + returned_value) / total_order_value, 1) AS lost_pct_of_order_value
FROM by_type
ORDER BY fulfilment;


-- [S19] LOST VALUE BY CATEGORY AND BY SIZE                          (client Q4)
-- What I check : for each category and each size, net revenue and its share, cancelled value,
--                returned value, lost value as % of order value, and the share of all lost value
-- Why          : turns the rate findings (S16, S17) into rupees and shows where the loss is bigger
--                than the revenue weight; within each cut the totals must tie to S1
-- Finding      : 20 rows (9 categories, 11 sizes) reconcile in each cut to S1: net revenue INR
--                69,660,658, cancelled value 6,919,284, returned value 1,384,559. Categories: Set 49.9%
--                of net revenue and 50.2% of lost value; Kurta 27.2% and 26.7%; Western Dress 14.1% and
--                15.1% (lost 11.2% of order value, the highest of the four big categories; mainly
--                returned value, 2.55% of net revenue vs 1.4-2.0% elsewhere, because 45% of its lines
--                are Merchant, the only fulfilment type with recorded returns); Top 6.9% and 6.2%.
--                Sizes: M has the largest loss (INR 1.58M, 19.0%), then L, XL, S; XS+S+M are 39.8% of
--                net revenue and 43.0% of lost value; lost % of order value falls from 11.5% (XS) to
--                9.4% (3XL). Cancelled value is a minimum (S18).
WITH base AS (
    SELECT 'category' AS cut_name, category AS cut_value, status_group, amount FROM clean.sales
    UNION ALL
    SELECT 'size', size, status_group, amount FROM clean.sales
),
grouped AS (
    SELECT
        cut_name,
        cut_value,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0), 0) AS net_revenue,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Cancelled'), 0)                AS cancelled_value,
        COALESCE(SUM(amount) FILTER (WHERE status_group = 'Returned'), 0)                 AS returned_value,
        COALESCE(SUM(amount), 0)                                                          AS total_order_value
    FROM base
    GROUP BY cut_name, cut_value
)
SELECT
    cut_name,
    cut_value,
    net_revenue,
    ROUND(100.0 * net_revenue / SUM(net_revenue) OVER (PARTITION BY cut_name), 1)         AS pct_of_net_revenue,
    cancelled_value,
    returned_value,
    ROUND(100.0 * (cancelled_value + returned_value)
          / NULLIF(total_order_value, 0), 1)                                              AS lost_pct_of_order_value,
    ROUND(100.0 * (cancelled_value + returned_value)
          / SUM(cancelled_value + returned_value) OVER (PARTITION BY cut_name), 1)        AS pct_of_all_lost_value
FROM grouped
ORDER BY
    cut_name,
    CASE WHEN cut_name = 'size' THEN
         CASE cut_value WHEN 'XS' THEN 1 WHEN 'S' THEN 2 WHEN 'M' THEN 3 WHEN 'L' THEN 4
                        WHEN 'XL' THEN 5 WHEN 'XXL' THEN 6 WHEN '3XL' THEN 7 WHEN '4XL' THEN 8
                        WHEN '5XL' THEN 9 WHEN '6XL' THEN 10 ELSE 11 END
    END,
    net_revenue DESC;


-- =================================== Q5: STOCKING ============================================

-- [S20] UNITS AND NET REVENUE BY SIZE                              (client Q5)
-- What I check : per size, units sold, share of units, net revenue, share of net revenue, revenue per
--                unit, and the running share of units from XS upwards
-- Why          : shows which sizes carry demand, for stocking; units use Completed, priced lines only
--                (cancelled lines have qty 0, so cancelled demand is not visible)
-- Finding      : 11 sizes reconcile: 105,484 units and INR 69,660,658 net revenue (equal to S19 per
--                size). Units peak in M (18,366 = 17.4%), L 17.1% and XL 16.3% (50.8% together); S to XXL
--                78.0%; XS 8.5%, 3XL 11.8%; 4XL-6XL together 1.4% (1,488 units); Free 0.3%. Demand is
--                skewed to larger sizes (XXL+3XL 26.0% vs XS+S 21.6%). Revenue per unit: INR 688 (XS) to
--                636 (XXL), 662 (3XL), 817-829 (4XL-6XL), 565 (Free). The XS-XXL slope is consistent with
--                category mix (Set is 49% of XS lines, 39% of 3XL lines); the 4XL-6XL level is
--                unexplained (Kurta, INR 464 per unit, makes up about 73% of their lines). Units count
--                Completed priced lines; cancelled demand (qty 0) is not visible, but line shares in S16
--                are within 0.2 points of unit shares.
WITH sized AS (
    SELECT
        size,
        CASE size
            WHEN 'XS'  THEN 1  WHEN 'S'   THEN 2  WHEN 'M'   THEN 3
            WHEN 'L'   THEN 4  WHEN 'XL'  THEN 5  WHEN 'XXL' THEN 6
            WHEN '3XL' THEN 7  WHEN '4XL' THEN 8  WHEN '5XL' THEN 9
            WHEN '6XL' THEN 10 ELSE 11
        END AS size_order,
        qty,
        amount
    FROM clean.sales
    WHERE status_group = 'Completed'
      AND amount > 0
)
SELECT
    size,
    SUM(qty)                                                                AS units_sold,
    ROUND(100.0 * SUM(qty) / SUM(SUM(qty)) OVER (), 1)                      AS pct_of_units,
    SUM(amount)                                                             AS net_revenue,
    ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER (), 1)                AS pct_of_net_revenue,
    ROUND(SUM(amount) / NULLIF(SUM(qty), 0), 0)                             AS revenue_per_unit,
    ROUND(100.0 * SUM(SUM(qty)) OVER (ORDER BY size_order)
          / SUM(SUM(qty)) OVER (), 1)                                       AS cumulative_pct_units
FROM sized
GROUP BY size, size_order
ORDER BY size_order;


-- [S21] UNITS BY SIZE AND FULFILMENT TYPE                           (client Q5)
-- What I check : per size, units sold under Amazon and under Merchant (Easy Ship), each size as a
--                share of its own channel's units, and Merchant's share of the size's units
-- Why          : stocking is decided per channel (stock at Amazon vs stock held at home); shows whether
--                the size mix differs between the two channels; totals must tie to S20
-- Finding      : 11 sizes reconcile: Amazon 76,330 + Merchant 29,154 = 105,484 units (each size equals
--                S20). Amazon is 72.4% of units, Merchant 27.6%. Size mix is nearly the same: no size
--                differs by more than 2.5 points (XS 9.2% of Amazon units vs 6.7% of Merchant; M 17.1%
--                vs 18.3%; L 16.7% vs 18.1%). XS+S are 22.6% of Amazon and 18.8% of Merchant units.
--                Merchant's share of a size's units is 21.9% (XS) to 29.4% (3XL). Net revenue per unit
--                is about the same: INR 659 (Amazon) vs 663 (Merchant), if amount is the line total.
--                Cancelled demand is not visible, and Merchant cancels more (S16), so its demand is
--                understated more.
WITH sized AS (
    SELECT
        size,
        CASE size
            WHEN 'XS'  THEN 1  WHEN 'S'   THEN 2  WHEN 'M'   THEN 3
            WHEN 'L'   THEN 4  WHEN 'XL'  THEN 5  WHEN 'XXL' THEN 6
            WHEN '3XL' THEN 7  WHEN '4XL' THEN 8  WHEN '5XL' THEN 9
            WHEN '6XL' THEN 10 ELSE 11
        END AS size_order,
        fulfilment,
        qty
    FROM clean.sales
    WHERE status_group = 'Completed'
      AND amount > 0
)
SELECT
    size,
    COALESCE(SUM(qty) FILTER (WHERE fulfilment = 'Amazon'), 0)                       AS amazon_units,
    ROUND(100.0 * SUM(qty) FILTER (WHERE fulfilment = 'Amazon')
          / SUM(SUM(qty) FILTER (WHERE fulfilment = 'Amazon')) OVER (), 1)           AS pct_of_amazon_units,
    COALESCE(SUM(qty) FILTER (WHERE fulfilment = 'Merchant'), 0)                     AS merchant_units,
    ROUND(100.0 * SUM(qty) FILTER (WHERE fulfilment = 'Merchant')
          / SUM(SUM(qty) FILTER (WHERE fulfilment = 'Merchant')) OVER (), 1)         AS pct_of_merchant_units,
    ROUND(100.0 * SUM(qty) FILTER (WHERE fulfilment = 'Merchant')
          / SUM(qty), 1)                                                             AS merchant_share_of_size_pct
FROM sized
GROUP BY size, size_order
ORDER BY size_order;


-- [S13c] WEEKLY NET REVENUE BY FULFILMENT TYPE                     (client Q3)
-- What I check : for each full week 4 Apr-26 Jun, net revenue and order lines for Amazon and for
--                Merchant, and Merchant's share of net revenue
-- Why          : S14b suggested the drop in the week of 9 May (S13) came from Amazon-fulfilled orders
--                and the later fall from Merchant orders; this tests it directly. Weekly totals must
--                tie to S13
-- Finding      : 12 weeks reconcile to S13: Amazon + Merchant equal each week's net revenue (INR
--                65,896,633 in total; Amazon 47,227,064, Merchant 18,669,569; 83,814 and 37,288 lines).
--                The two drops come from different channels. Amazon net revenue falls 41.4% in the week
--                of 9 May (INR 4,810,419 to 2,819,301; lines 8,795 to 4,852) and stays low in the week of
--                16 May, recovers to 4,109,586 (+48.1%) in the week of 23 May and 4,453,972 by 6 June,
--                then eases to 3,298,130 by 20 June. Merchant net revenue rises 11.4% in the week of 9
--                May, then falls 47.7% in the week of 23 May (INR 1,878,761 to 982,929; lines 3,601 to
--                1,986) and stays about 28% below its 4 Apr-2 May average (INR 1.27M vs 1.77M per week);
--                Amazon's last four weeks are about 10% below its average. Merchant share of net revenue
--                ranges 19.3-40.4%. The early-May peak is a short burst (1-4 May, A12b). Causes are not
--                in the data.
SELECT
    DATE_TRUNC('week', order_date)::date                                              AS week_start,
    COALESCE(SUM(amount) FILTER (WHERE fulfilment = 'Amazon'
                                   AND status_group = 'Completed' AND amount > 0), 0)  AS amazon_net_revenue,
    COALESCE(SUM(amount) FILTER (WHERE fulfilment = 'Merchant'
                                   AND status_group = 'Completed' AND amount > 0), 0)  AS merchant_net_revenue,
    COUNT(*) FILTER (WHERE fulfilment = 'Amazon')                                     AS amazon_lines,
    COUNT(*) FILTER (WHERE fulfilment = 'Merchant')                                   AS merchant_lines,
    ROUND(100.0 * SUM(amount) FILTER (WHERE fulfilment = 'Merchant'
                                        AND status_group = 'Completed' AND amount > 0)
          / SUM(amount) FILTER (WHERE status_group = 'Completed' AND amount > 0), 1)  AS merchant_share_of_net_revenue_pct
FROM clean.sales
WHERE order_date BETWEEN DATE '2022-04-04' AND DATE '2022-06-26'
GROUP BY week_start
ORDER BY week_start;
------------------------------------












