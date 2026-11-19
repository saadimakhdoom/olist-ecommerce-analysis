/* =====================================================================
   Olist E-commerce | Phase 3: Business Analysis
   Database: PostgreSQL

   Business questions
   1. Which states bring in the most revenue?
   2. Which cities are the top performers?
   3. Which sellers are underperforming?
   4. Should Olist focus on key areas rather than selling everywhere?

   Definitions (same as Phase 2)
   - Revenue  = item price of delivered orders (excludes freight)
   - Period   = Jan 2017 - Aug 2018
   - Customer = customer_unique_id
   Profit cannot be calculated: the dataset contains no product cost or
   seller margin data. Seller performance is therefore measured with a
   scorecard (revenue, reviews, late deliveries, cancellations, freight).

   Each step returns its own result and is run individually.
   ===================================================================== */


/* =====================================================================
   Step 3.0: Reference table of Brazilian states and regions

   The source data holds only two-letter state codes (SP, RJ ...).
   A small lookup table adds the full state name and the official
   region (North, Northeast, Centre-West, Southeast, South), so results
   can be read by non-specialists and grouped regionally. Region-level
   comparison is central to the question of where to focus.

   Also used as a dimension table in the Power BI model.
   ===================================================================== */

DROP TABLE IF EXISTS ref_states;
CREATE TABLE ref_states (
    state_code CHAR(2)      PRIMARY KEY,
    state_name VARCHAR(40)  NOT NULL,
    region     VARCHAR(20)  NOT NULL
);

INSERT INTO ref_states (state_code, state_name, region) VALUES
    ('AC', 'Acre',                'North'),
    ('AP', 'Amapá',               'North'),
    ('AM', 'Amazonas',            'North'),
    ('PA', 'Pará',                'North'),
    ('RO', 'Rondônia',            'North'),
    ('RR', 'Roraima',             'North'),
    ('TO', 'Tocantins',           'North'),
    ('AL', 'Alagoas',             'Northeast'),
    ('BA', 'Bahia',               'Northeast'),
    ('CE', 'Ceará',               'Northeast'),
    ('MA', 'Maranhão',            'Northeast'),
    ('PB', 'Paraíba',             'Northeast'),
    ('PE', 'Pernambuco',          'Northeast'),
    ('PI', 'Piauí',               'Northeast'),
    ('RN', 'Rio Grande do Norte', 'Northeast'),
    ('SE', 'Sergipe',             'Northeast'),
    ('DF', 'Distrito Federal',    'Centre-West'),
    ('GO', 'Goiás',               'Centre-West'),
    ('MT', 'Mato Grosso',         'Centre-West'),
    ('MS', 'Mato Grosso do Sul',  'Centre-West'),
    ('ES', 'Espírito Santo',      'Southeast'),
    ('MG', 'Minas Gerais',        'Southeast'),
    ('RJ', 'Rio de Janeiro',      'Southeast'),
    ('SP', 'São Paulo',           'Southeast'),
    ('PR', 'Paraná',              'South'),
    ('RS', 'Rio Grande do Sul',   'South'),
    ('SC', 'Santa Catarina',      'South');

-- Check: 27 states, and every customer state in the data has a match.
SELECT (SELECT COUNT(*) FROM ref_states)                               AS states_loaded,
       (SELECT COUNT(DISTINCT customer_state)
          FROM stg_customers c
         WHERE NOT EXISTS (SELECT 1 FROM ref_states r
                            WHERE r.state_code = c.customer_state))   AS unmatched_states;


/* =====================================================================
   Step 3.1: Revenue by customer state (Business question 1)

   Ranks all 27 states by revenue, with orders, customers, average
   order value and each state's share of total revenue. The cumulative
   share (running total, largest state first) shows how few states
   account for most of the revenue: a Pareto view.

   Revenue is assigned to the CUSTOMER's state, i.e. where demand is.
   RANK() numbers the states by revenue; SUM() OVER (ORDER BY ...)
   produces the running total.
   ===================================================================== */

WITH state_sales AS (
    SELECT customer_state                     AS state_code,
           SUM(price)                         AS revenue,
           COUNT(DISTINCT order_id)           AS orders,
           COUNT(DISTINCT customer_unique_id) AS customers
    FROM vw_sales_items
    GROUP BY customer_state
)
SELECT RANK() OVER (ORDER BY s.revenue DESC)                                       AS revenue_rank,
       s.state_code,
       r.state_name,
       r.region,
       ROUND(s.revenue, 0)                                                         AS revenue,
       s.orders,
       s.customers,
       ROUND(s.revenue / s.orders, 2)                                              AS avg_order_value,
       ROUND(100.0 * s.revenue / SUM(s.revenue) OVER (), 1)                        AS pct_of_revenue,
       ROUND(100.0 * SUM(s.revenue) OVER (ORDER BY s.revenue DESC)
                   / SUM(s.revenue) OVER (), 1)                                    AS cumulative_pct
FROM state_sales AS s
JOIN ref_states  AS r ON r.state_code = s.state_code
ORDER BY s.revenue DESC;


/* =====================================================================
   Step 3.2: Service quality by state (Business question 1, continued)

   Revenue alone does not show how well, or how efficiently, each state
   is served. For every state this adds:
   - freight as a % of price (cost of shipping relative to sales value)
   - average delivery time in days
   - share of orders delivered late
   - average review score
   States that combine low revenue with high freight, slow delivery and
   poor reviews are costly to serve and weak candidates for growth
   investment; strong states are where to focus.

   Freight is measured per item (vw_sales_items). Delivery and reviews
   are measured per order (stg_orders + stg_reviews), so each order
   counts once. The two CTEs are joined on state.
   ===================================================================== */

WITH item_metrics AS (
    SELECT customer_state      AS state_code,
           SUM(price)          AS revenue,
           SUM(freight_value)  AS freight
    FROM vw_sales_items
    GROUP BY customer_state
),
order_metrics AS (
    SELECT c.customer_state                                 AS state_code,
           AVG(o.delivery_days)                             AS avg_delivery_days,
           AVG(CASE WHEN o.is_late THEN 1.0 ELSE 0.0 END)   AS late_rate,
           AVG(r.review_score)                              AS avg_review
    FROM stg_orders         AS o
    JOIN stg_customers      AS c ON c.customer_id = o.customer_id
    LEFT JOIN stg_reviews   AS r ON r.order_id    = o.order_id
    WHERE o.is_delivered
      AND o.in_analysis_window
      AND o.delivery_days IS NOT NULL
    GROUP BY c.customer_state
)
SELECT RANK() OVER (ORDER BY i.revenue DESC)        AS revenue_rank,
       i.state_code,
       s.state_name,
       s.region,
       ROUND(i.revenue, 0)                          AS revenue,
       ROUND(100.0 * i.freight / i.revenue, 1)      AS freight_pct_of_price,
       ROUND(o.avg_delivery_days, 1)                AS avg_delivery_days,
       ROUND(100.0 * o.late_rate, 1)                AS pct_late,
       ROUND(o.avg_review, 2)                       AS avg_review
FROM item_metrics  AS i
JOIN order_metrics AS o ON o.state_code = i.state_code
JOIN ref_states    AS s ON s.state_code = i.state_code
ORDER BY i.revenue DESC;


/* =====================================================================
   Step 3.3: Regional summary (Business questions 1 and 4)

   Rolls the state results up to Brazil's five official regions, the
   level at which a focus strategy would be set. For each region:
   share of revenue, customers and sellers, average order value,
   freight as a % of price, delivery time, late rate and average review.

   Comparing a region's share of revenue with its share of sellers
   shows where demand is served by local supply and where products
   must travel long distances. Grains are kept separate (items for
   revenue and freight, orders for delivery and reviews, sellers for
   supply) and joined on region.
   ===================================================================== */

WITH item_metrics AS (
    SELECT s.region,
           SUM(v.price)                         AS revenue,
           SUM(v.freight_value)                 AS freight,
           COUNT(DISTINCT v.order_id)           AS orders,
           COUNT(DISTINCT v.customer_unique_id) AS customers
    FROM vw_sales_items AS v
    JOIN ref_states     AS s ON s.state_code = v.customer_state
    GROUP BY s.region
),
order_metrics AS (
    SELECT s.region,
           AVG(o.delivery_days)                             AS avg_delivery_days,
           AVG(CASE WHEN o.is_late THEN 1.0 ELSE 0.0 END)   AS late_rate,
           AVG(r.review_score)                              AS avg_review
    FROM stg_orders       AS o
    JOIN stg_customers    AS c ON c.customer_id = o.customer_id
    JOIN ref_states       AS s ON s.state_code  = c.customer_state
    LEFT JOIN stg_reviews AS r ON r.order_id    = o.order_id
    WHERE o.is_delivered
      AND o.in_analysis_window
      AND o.delivery_days IS NOT NULL
    GROUP BY s.region
),
seller_metrics AS (
    SELECT s.region,
           COUNT(DISTINCT v.seller_id) AS sellers
    FROM vw_sales_items AS v
    JOIN ref_states     AS s ON s.state_code = v.seller_state
    GROUP BY s.region
)
SELECT i.region,
       ROUND(i.revenue, 0)                                       AS revenue,
       ROUND(100.0 * i.revenue   / SUM(i.revenue)   OVER (), 1)  AS pct_of_revenue,
       ROUND(100.0 * i.customers / SUM(i.customers) OVER (), 1)  AS pct_of_customers,
       ROUND(100.0 * COALESCE(sm.sellers, 0)
                   / (SELECT SUM(sellers) FROM seller_metrics), 1) AS pct_of_sellers,
       ROUND(i.revenue / i.orders, 2)                            AS avg_order_value,
       ROUND(100.0 * i.freight / i.revenue, 1)                   AS freight_pct_of_price,
       ROUND(o.avg_delivery_days, 1)                             AS avg_delivery_days,
       ROUND(100.0 * o.late_rate, 1)                             AS pct_late,
       ROUND(o.avg_review, 2)                                    AS avg_review
FROM item_metrics        AS i
JOIN order_metrics       AS o  ON o.region  = i.region
LEFT JOIN seller_metrics AS sm ON sm.region = i.region
ORDER BY i.revenue DESC;


/* =====================================================================
   Step 3.4: Top 20 cities by revenue (Business question 2)

   Ranks customer cities by revenue, with orders, customers, average
   order value, share of total revenue and the cumulative share of the
   top 20. Cities are grouped by city AND state, because several
   Brazilian cities share a name across different states.

   Shows how concentrated demand is at city level, the most precise
   level for targeted marketing and delivery improvements.
   ===================================================================== */

WITH city_sales AS (
    SELECT customer_city                      AS city,
           customer_state                     AS state_code,
           SUM(price)                         AS revenue,
           COUNT(DISTINCT order_id)           AS orders,
           COUNT(DISTINCT customer_unique_id) AS customers
    FROM vw_sales_items
    GROUP BY customer_city, customer_state
),
ranked AS (
    SELECT c.*,
           RANK() OVER (ORDER BY revenue DESC)                          AS revenue_rank,
           100.0 * revenue / SUM(revenue) OVER ()                       AS pct_of_revenue,
           100.0 * SUM(revenue) OVER (ORDER BY revenue DESC)
                 / SUM(revenue) OVER ()                                 AS cumulative_pct
    FROM city_sales AS c
)
SELECT r.revenue_rank,
       INITCAP(r.city)                 AS city,
       r.state_code,
       s.region,
       ROUND(r.revenue, 0)             AS revenue,
       r.orders,
       r.customers,
       ROUND(r.revenue / r.orders, 2)  AS avg_order_value,
       ROUND(r.pct_of_revenue, 1)      AS pct_of_revenue,
       ROUND(r.cumulative_pct, 1)      AS cumulative_pct
FROM ranked     AS r
JOIN ref_states AS s ON s.state_code = r.state_code
WHERE r.revenue_rank <= 20
ORDER BY r.revenue_rank;


/* =====================================================================
   Step 3.5: Growth of the top 20 cities, 2017 vs 2018 (Business question 2)

   Compares revenue for the same eight months in each year
   (Jan-Aug 2017 vs Jan-Aug 2018) for the 20 largest cities, so the
   comparison is like-for-like and unaffected by seasonality.
   Identifies which large markets are growing fastest (where to invest
   next) and which are slowing.

   FILTER (WHERE ...) restricts each SUM to one period within a single
   pass over the data.
   ===================================================================== */

WITH city_years AS (
    SELECT customer_city  AS city,
           customer_state AS state_code,
           SUM(price)                                                       AS total_revenue,
           SUM(price) FILTER (WHERE purchase_month BETWEEN '2017-01-01' AND '2017-08-01') AS rev_2017_jan_aug,
           SUM(price) FILTER (WHERE purchase_month BETWEEN '2018-01-01' AND '2018-08-01') AS rev_2018_jan_aug
    FROM vw_sales_items
    GROUP BY customer_city, customer_state
),
top_cities AS (
    SELECT *,
           RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank
    FROM city_years
)
SELECT revenue_rank,
       INITCAP(city)                                         AS city,
       state_code,
       ROUND(rev_2017_jan_aug, 0)                            AS rev_2017_jan_aug,
       ROUND(rev_2018_jan_aug, 0)                            AS rev_2018_jan_aug,
       ROUND(100.0 * (rev_2018_jan_aug - rev_2017_jan_aug)
                   / rev_2017_jan_aug, 1)                    AS growth_pct
FROM top_cities
WHERE revenue_rank <= 20
ORDER BY growth_pct DESC;


/* =====================================================================
   Step 3.6a: Seller scorecard view (Business question 3)

   The dataset has no cost or margin data, so seller profit cannot be
   calculated. Seller performance is measured with a scorecard instead,
   one row per seller with activity in the analysis window:
   - total and delivered orders, revenue, items, average item price
   - freight as a % of price      (cost to the customer of shipping)
   - average review score         (customer satisfaction)
   - late delivery rate           (reliability)
   - lost order rate              (canceled or unavailable orders)
   - first and last month of sales (tenure and whether still active)

   Saved as a view so segmentation (Step 3.7) and the Power BI model
   use exactly the same seller metrics.

   seller_orders lists each (seller, order) pair once, because an order
   with several items from the same seller must count as one order.
   ===================================================================== */

CREATE OR REPLACE VIEW vw_seller_scorecard AS
WITH seller_orders AS (
    SELECT DISTINCT i.seller_id,
           o.order_id,
           o.order_status,
           o.is_delivered,
           o.is_late,
           o.delivery_days,
           o.purchase_month
    FROM stg_order_items AS i
    JOIN stg_orders      AS o ON o.order_id = i.order_id
    WHERE o.in_analysis_window
),
order_stats AS (
    SELECT seller_id,
           COUNT(*)                                                         AS total_orders,
           COUNT(*) FILTER (WHERE is_delivered)                             AS delivered_orders,
           COUNT(*) FILTER (WHERE order_status IN ('canceled', 'unavailable')) AS lost_orders,
           AVG(CASE WHEN is_late THEN 1.0 ELSE 0.0 END)
               FILTER (WHERE is_delivered AND is_late IS NOT NULL)          AS late_rate,
           AVG(delivery_days) FILTER (WHERE is_delivered)                   AS avg_delivery_days,
           MIN(purchase_month)                                              AS first_month,
           MAX(purchase_month)                                              AS last_month
    FROM seller_orders
    GROUP BY seller_id
),
sales AS (
    SELECT seller_id,
           SUM(price)          AS revenue,
           SUM(freight_value)  AS freight,
           COUNT(*)            AS items_sold
    FROM vw_sales_items
    GROUP BY seller_id
),
reviews AS (
    SELECT so.seller_id,
           AVG(r.review_score) AS avg_review,
           COUNT(*)            AS reviewed_orders
    FROM seller_orders AS so
    JOIN stg_reviews   AS r ON r.order_id = so.order_id
    WHERE so.is_delivered
    GROUP BY so.seller_id
)
SELECT os.seller_id,
       INITCAP(s.seller_city)                               AS seller_city,
       s.seller_state,
       rs.region                                            AS seller_region,
       os.total_orders,
       os.delivered_orders,
       COALESCE(sa.items_sold, 0)                           AS items_sold,
       COALESCE(sa.revenue, 0)                              AS revenue,
       ROUND(sa.revenue / NULLIF(sa.items_sold, 0), 2)      AS avg_item_price,
       ROUND(100.0 * sa.freight / NULLIF(sa.revenue, 0), 1) AS freight_pct_of_price,
       ROUND(rv.avg_review, 2)                              AS avg_review,
       rv.reviewed_orders,
       ROUND(100.0 * os.late_rate, 1)                       AS pct_late,
       ROUND(100.0 * os.lost_orders / os.total_orders, 1)   AS pct_lost,
       ROUND(os.avg_delivery_days, 1)                       AS avg_delivery_days,
       os.first_month,
       os.last_month
FROM order_stats     AS os
JOIN stg_sellers     AS s  ON s.seller_id   = os.seller_id
LEFT JOIN sales      AS sa ON sa.seller_id  = os.seller_id
LEFT JOIN reviews    AS rv ON rv.seller_id  = os.seller_id
LEFT JOIN ref_states AS rs ON rs.state_code = s.seller_state;


/* =====================================================================
   Step 3.6b: Scorecard check and top 10 sellers

   Confirms the scorecard reconciles to total revenue (R$13,181,027 from
   the Phase 1 validation), then shows the ten largest sellers with
   their share of total revenue and their quality metrics.
   ===================================================================== */

SELECT RANK() OVER (ORDER BY revenue DESC)                              AS revenue_rank,
       LEFT(seller_id, 8)                                               AS seller,
       seller_city,
       seller_state,
       delivered_orders,
       ROUND(revenue, 0)                                                AS revenue,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)                 AS pct_of_revenue,
       avg_item_price,
       avg_review,
       pct_late,
       pct_lost,
       (SELECT COUNT(*) FROM vw_seller_scorecard)                       AS sellers_in_scorecard,
       (SELECT ROUND(SUM(revenue), 0) FROM vw_seller_scorecard)         AS total_revenue_check
FROM vw_seller_scorecard
ORDER BY revenue DESC
LIMIT 10;


/* =====================================================================
   Step 3.7a: Seller segments view (Business question 3)

   Groups every seller into one segment using the scorecard:
   1. Long tail - fewer than 10 delivered orders: too little activity
                  to judge performance reliably
   2. At risk   - 10+ orders AND (average review below 3.5 OR more than
                  15% of orders delivered late): poor customer outcomes
   3. Star      - 10+ orders, not at risk, top 20% by revenue
   4. Solid     - every other seller with 10+ orders, not at risk
   Rules are applied in this order, so each seller gets exactly one
   segment. NTILE(5) splits qualifying sellers into revenue fifths;
   the top fifth are Stars.

   is_inactive flags sellers with no sales since May 2018 (no orders in
   the last three months of the window).
   ===================================================================== */

CREATE OR REPLACE VIEW vw_seller_segments AS
WITH flagged AS (
    SELECT sc.*,
           (delivered_orders >= 10)                                  AS is_established,
           (delivered_orders >= 10
             AND (avg_review < 3.5 OR pct_late > 15))                AS is_at_risk,
           (last_month < '2018-06-01')                               AS is_inactive
    FROM vw_seller_scorecard AS sc
),
ranked AS (
    SELECT f.*,
           CASE WHEN is_established AND NOT is_at_risk
                THEN NTILE(5) OVER (PARTITION BY (is_established AND NOT is_at_risk)
                                    ORDER BY revenue DESC)
           END AS revenue_quintile
    FROM flagged AS f
)
SELECT r.*,
       CASE
           WHEN NOT is_established     THEN 'Long tail'
           WHEN is_at_risk             THEN 'At risk'
           WHEN revenue_quintile = 1   THEN 'Star'
           ELSE                             'Solid'
       END AS segment
FROM ranked AS r;


/* =====================================================================
   Step 3.7b: Segment summary

   Size and value of each segment: sellers, share of sellers, revenue,
   share of revenue, average order value, order-weighted review score
   and late rate, and how many sellers in the segment are inactive.
   Shows where revenue comes from and how much revenue sits with
   sellers whose customers have poor experiences.

   Review and late rate are weighted by orders, so a seller with 1,000
   orders counts more than a seller with 10.
   ===================================================================== */

SELECT segment,
       COUNT(*)                                                         AS sellers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)               AS pct_of_sellers,
       ROUND(SUM(revenue), 0)                                           AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)       AS pct_of_revenue,
       ROUND(SUM(revenue) / NULLIF(SUM(delivered_orders), 0), 2)        AS avg_order_value,
       ROUND(SUM(avg_review * reviewed_orders)
             / NULLIF(SUM(reviewed_orders), 0), 2)                      AS avg_review,
       ROUND(SUM(pct_late * delivered_orders)
             / NULLIF(SUM(delivered_orders), 0), 1)                     AS pct_late,
       COUNT(*) FILTER (WHERE is_inactive)                              AS inactive_sellers
FROM vw_seller_segments
GROUP BY segment
ORDER BY revenue DESC;


/* =====================================================================
   Step 3.8: At-risk sellers with the most revenue at stake (Business question 3)

   Lists the 15 at-risk sellers with the highest revenue: the sellers
   where improving delivery or customer experience would protect the
   most revenue and the most customers. Each seller is tagged with its
   main issue (poor reviews, late delivery, or both) to guide the
   action: quality support, logistics support, or review of the
   seller's place on the marketplace.
   ===================================================================== */

SELECT RANK() OVER (ORDER BY revenue DESC)                        AS risk_rank,
       LEFT(seller_id, 8)                                         AS seller,
       seller_city,
       seller_state,
       delivered_orders,
       ROUND(revenue, 0)                                          AS revenue,
       avg_review,
       pct_late,
       pct_lost,
       CASE
           WHEN avg_review < 3.5 AND pct_late > 15 THEN 'Poor reviews and late delivery'
           WHEN avg_review < 3.5                   THEN 'Poor reviews'
           ELSE                                         'Late delivery'
       END                                                        AS main_issue,
       CASE WHEN is_inactive THEN 'Inactive' ELSE 'Active' END    AS status
FROM vw_seller_segments
WHERE segment = 'At risk'
ORDER BY revenue DESC
LIMIT 15;


/* =====================================================================
   Step 3.9: Which categories travel well? (Business question 4)

   For the 15 highest-revenue categories, compares the core market
   (Southeast + South, ~80% of revenue and 95% of sellers) with the rest
   of Brazil (Northeast, Centre-West, North):
   - share of the category's revenue coming from outside the core
   - freight as a % of price inside and outside the core
   - the freight gap between the two (percentage points)

   Categories with low freight outside the core (small, light, valuable
   items) can be promoted nationally. Categories where freight becomes
   a large share of the price outside the core (bulky or low-value
   items) are better focused on the core market, unless local supply
   is developed.
   ===================================================================== */

WITH base AS (
    SELECT v.category,
           (r.region IN ('Southeast', 'South')) AS is_core,
           v.price,
           v.freight_value
    FROM vw_sales_items AS v
    JOIN ref_states     AS r ON r.state_code = v.customer_state
),
by_category AS (
    SELECT category,
           SUM(price)                                                AS revenue,
           SUM(price)         FILTER (WHERE NOT is_core)             AS revenue_outside_core,
           SUM(freight_value) FILTER (WHERE is_core)
             / NULLIF(SUM(price) FILTER (WHERE is_core), 0)          AS freight_ratio_core,
           SUM(freight_value) FILTER (WHERE NOT is_core)
             / NULLIF(SUM(price) FILTER (WHERE NOT is_core), 0)      AS freight_ratio_outside
    FROM base
    GROUP BY category
)
SELECT RANK() OVER (ORDER BY revenue DESC)                         AS revenue_rank,
       category,
       ROUND(revenue, 0)                                           AS revenue,
       ROUND(100.0 * revenue_outside_core / revenue, 1)            AS pct_revenue_outside_core,
       ROUND(100.0 * freight_ratio_core, 1)                        AS freight_pct_core,
       ROUND(100.0 * freight_ratio_outside, 1)                     AS freight_pct_outside_core,
       ROUND(100.0 * (freight_ratio_outside - freight_ratio_core), 1) AS freight_gap_pts
FROM by_category
ORDER BY revenue DESC
LIMIT 15;


/* =====================================================================
   Step 3.10: State focus matrix (Business question 4)

   Brings the analysis together at state level: revenue share,
   like-for-like growth (Jan-Aug 2017 vs Jan-Aug 2018), late delivery
   rate, average review and freight as a % of price, plus a recommended
   strategy for each state based on the findings:

   - Protect & grow       Southeast/South states with good delivery
                          (late rate 10% or below): the core market
   - Fix delivery         Southeast/South states with late rate above
                          10%: large markets held back by reliability
   - Develop local supply Northeast states: meaningful demand served
                          almost entirely by distant sellers
   - Maintain             Centre-West states: moderate demand, average
                          service
   - Selective            North states: small, costly to serve; focus
                          on high-value, light products

   Saved as a view for the Power BI dashboard.
   ===================================================================== */

CREATE OR REPLACE VIEW vw_state_focus AS
WITH sales AS (
    SELECT customer_state                                                                  AS state_code,
           SUM(price)                                                                      AS revenue,
           SUM(freight_value)                                                              AS freight,
           SUM(price) FILTER (WHERE purchase_month BETWEEN '2017-01-01' AND '2017-08-01')  AS rev_2017,
           SUM(price) FILTER (WHERE purchase_month BETWEEN '2018-01-01' AND '2018-08-01')  AS rev_2018
    FROM vw_sales_items
    GROUP BY customer_state
),
service AS (
    SELECT c.customer_state                                AS state_code,
           AVG(CASE WHEN o.is_late THEN 1.0 ELSE 0.0 END)  AS late_rate,
           AVG(r.review_score)                             AS avg_review
    FROM stg_orders       AS o
    JOIN stg_customers    AS c ON c.customer_id = o.customer_id
    LEFT JOIN stg_reviews AS r ON r.order_id    = o.order_id
    WHERE o.is_delivered
      AND o.in_analysis_window
      AND o.delivery_days IS NOT NULL
    GROUP BY c.customer_state
)
SELECT s.state_code,
       rs.state_name,
       rs.region,
       ROUND(s.revenue, 0)                                       AS revenue,
       ROUND(100.0 * s.revenue / SUM(s.revenue) OVER (), 1)      AS pct_of_revenue,
       ROUND(100.0 * (s.rev_2018 - s.rev_2017) / s.rev_2017, 1)  AS growth_pct,
       ROUND(100.0 * sv.late_rate, 1)                            AS pct_late,
       ROUND(sv.avg_review, 2)                                   AS avg_review,
       ROUND(100.0 * s.freight / s.revenue, 1)                   AS freight_pct_of_price,
       CASE
           WHEN rs.region IN ('Southeast', 'South') AND sv.late_rate <= 0.10 THEN 'Protect & grow'
           WHEN rs.region IN ('Southeast', 'South')                          THEN 'Fix delivery'
           WHEN rs.region = 'Northeast'                                      THEN 'Develop local supply'
           WHEN rs.region = 'Centre-West'                                    THEN 'Maintain'
           ELSE                                                                   'Selective'
       END                                                       AS strategy
FROM sales           AS s
JOIN service         AS sv ON sv.state_code = s.state_code
JOIN ref_states      AS rs ON rs.state_code = s.state_code;


/* =====================================================================
   Step 3.10b: Strategy summary

   Revenue, share of revenue, growth, late rate and review for each
   recommended strategy group, ordered by revenue.
   ===================================================================== */

SELECT strategy,
       COUNT(*)                                                    AS states,
       STRING_AGG(state_code, ', ' ORDER BY revenue DESC)          AS state_list,
       SUM(revenue)                                                AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)  AS pct_of_revenue,
       ROUND(SUM(pct_late * revenue) / SUM(revenue), 1)            AS pct_late_weighted,
       ROUND(SUM(avg_review * revenue) / SUM(revenue), 2)          AS avg_review_weighted
FROM vw_state_focus
GROUP BY strategy
ORDER BY revenue DESC;
