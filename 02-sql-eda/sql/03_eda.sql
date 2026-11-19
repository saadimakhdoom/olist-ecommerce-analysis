/* =====================================================================
   Olist E-commerce | Phase 2: Exploratory Data Analysis (EDA)
   Database: PostgreSQL

   Purpose
   Understand the shape of the business before answering the main
   business questions: size, growth, seasonality, typical orders,
   payments, delivery performance, customer satisfaction, product mix,
   retention and geography.

   Definitions used throughout
   - Revenue  = item price of delivered orders (excludes freight)
   - Period   = Jan 2017 - Aug 2018 (the 20 complete months)
   - Customer = customer_unique_id (customer_id changes with every order)

   Each step returns its own result and is run individually.
   Step 2.0 creates the view used by most later steps.
   ===================================================================== */


/* =====================================================================
   Step 2.0: Reusable view of delivered sales

   Most EDA and business-analysis questions need the same base data:
   items from delivered orders in the analysis window, joined to
   customer, seller and product details. Defining this once as a view
   keeps every metric on identical rules, so results from different
   queries always reconcile. Phase 3 and the Power BI dataset reuse it.

   Grain: one row per item sold.
   ===================================================================== */

CREATE OR REPLACE VIEW vw_sales_items AS
SELECT i.order_id,
       i.order_item_id,
       o.order_purchase_timestamp,
       o.purchase_month,
       o.delivery_days,
       o.is_late,
       c.customer_unique_id,
       c.customer_city,
       c.customer_state,
       i.seller_id,
       s.seller_city,
       s.seller_state,
       i.product_id,
       p.product_category_english AS category,
       p.product_weight_g,
       i.price,
       i.freight_value
FROM stg_order_items AS i
JOIN stg_orders      AS o ON o.order_id    = i.order_id
JOIN stg_customers   AS c ON c.customer_id = o.customer_id
JOIN stg_sellers     AS s ON s.seller_id   = i.seller_id
JOIN stg_products    AS p ON p.product_id  = i.product_id
WHERE o.is_delivered
  AND o.in_analysis_window;


/* =====================================================================
   Step 2.1: Business overview

   Headline figures for the analysis period in a single row: date range,
   order and customer volumes, active sellers, revenue, freight, average
   order value (AOV) and basket size. These form the baseline that
   later breakdowns are measured against.

   COUNT(DISTINCT ...) is used for orders and customers because the view
   holds one row per item, and one order can contain several items.
   ===================================================================== */

SELECT MIN(order_purchase_timestamp)::date                    AS first_order,
       MAX(order_purchase_timestamp)::date                    AS last_order,
       COUNT(DISTINCT order_id)                               AS delivered_orders,
       COUNT(*)                                               AS items_sold,
       COUNT(DISTINCT customer_unique_id)                     AS customers,
       COUNT(DISTINCT seller_id)                              AS active_sellers,
       COUNT(DISTINCT category)                               AS categories,
       ROUND(SUM(price), 0)                                   AS revenue,
       ROUND(SUM(freight_value), 0)                           AS freight,
       ROUND(SUM(price) / COUNT(DISTINCT order_id), 2)        AS avg_order_value,
       ROUND(COUNT(*)::numeric / COUNT(DISTINCT order_id), 2) AS avg_items_per_order
FROM vw_sales_items;


/* =====================================================================
   Step 2.2: Order status mix

   Breakdown of all orders by status across the full dataset, showing
   how many orders did not reach the customer (canceled, unavailable,
   still in transit). Revenue metrics use delivered orders only, so
   this quantifies what that definition excludes.

   SUM(COUNT(*)) OVER () is a window function that returns the grand
   total on every row, allowing the percentage share to be calculated
   in a single query.
   ===================================================================== */

SELECT order_status,
       COUNT(*)                                           AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders
FROM stg_orders
GROUP BY order_status
ORDER BY orders DESC;


/* =====================================================================
   Step 2.3: Monthly trend and month-on-month growth

   Orders, revenue and average order value for each month of the
   analysis window, plus revenue growth versus the previous month.
   Shows whether the business is growing, flat or seasonal.

   The CTE (WITH monthly AS ...) first aggregates sales to one row per
   month. LAG() then reads the previous month's revenue on each row,
   so month-on-month growth is calculated without a self-join.
   ===================================================================== */

WITH monthly AS (
    SELECT purchase_month,
           COUNT(DISTINCT order_id) AS orders,
           SUM(price)               AS revenue
    FROM vw_sales_items
    GROUP BY purchase_month
)
SELECT purchase_month,
       orders,
       ROUND(revenue, 0)                                                  AS revenue,
       ROUND(revenue / orders, 2)                                         AS avg_order_value,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY purchase_month))
                   / LAG(revenue) OVER (ORDER BY purchase_month), 1)      AS revenue_growth_pct
FROM monthly
ORDER BY purchase_month;


/* =====================================================================
   Step 2.4: Busiest trading days

   The ten days with the most delivered orders, with weekday and
   revenue. Identifies the specific dates behind seasonal peaks (such
   as Black Friday), which matter for planning stock, delivery capacity
   and marketing.
   ===================================================================== */

SELECT order_purchase_timestamp::date            AS order_date,
       TO_CHAR(order_purchase_timestamp, 'Day')  AS weekday,
       COUNT(DISTINCT order_id)                  AS orders,
       ROUND(SUM(price), 0)                      AS revenue
FROM vw_sales_items
GROUP BY order_purchase_timestamp::date,
         TO_CHAR(order_purchase_timestamp, 'Day')
ORDER BY orders DESC
LIMIT 10;


/* =====================================================================
   Step 2.5: Price and freight distribution (per item)

   Minimum, quartiles, median, average, 95th percentile and maximum for
   item price and freight cost. The median and percentiles describe a
   typical item better than the average, which a small number of very
   expensive items (outliers) pulls upwards. Comparing the two rows
   shows how large shipping is relative to product value.
   ===================================================================== */

SELECT 'price'                                                                 AS measure,
       MIN(price)                                                              AS min_value,
       ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price)::numeric, 2)  AS p25,
       ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY price)::numeric, 2)  AS median,
       ROUND(AVG(price), 2)                                                    AS average,
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price)::numeric, 2)  AS p75,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY price)::numeric, 2)  AS p95,
       MAX(price)                                                              AS max_value
FROM vw_sales_items

UNION ALL

SELECT 'freight',
       MIN(freight_value),
       ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY freight_value)::numeric, 2),
       ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY freight_value)::numeric, 2),
       ROUND(AVG(freight_value), 2),
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY freight_value)::numeric, 2),
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY freight_value)::numeric, 2),
       MAX(freight_value)
FROM vw_sales_items;


/* =====================================================================
   Step 2.6: Basket size (items per order)

   Share of delivered orders by number of items. Shows how often
   customers buy more than one item, which indicates the scope for
   cross-selling and bundle offers to raise average order value.

   The CTE counts items per order; the outer query groups orders into
   1, 2, 3 and 4+ items and calculates each group's share.
   ===================================================================== */

WITH order_sizes AS (
    SELECT order_id,
           COUNT(*) AS items
    FROM vw_sales_items
    GROUP BY order_id
)
SELECT CASE WHEN items >= 4 THEN '4+' ELSE items::text END AS items_in_order,
       COUNT(*)                                             AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS pct_of_orders
FROM order_sizes
GROUP BY 1
ORDER BY 1;


/* =====================================================================
   Step 2.7: Payment methods

   Payment behaviour for delivered orders in the analysis window:
   number of orders, share of total value, average payment and average
   number of instalments per payment method. In Brazil, splitting card
   payments into instalments (parcelas) is common, and boleto (bank
   payment slip) serves customers without credit cards.

   Uses the payments table directly, as an order can be paid with more
   than one method (e.g. voucher plus credit card).
   ===================================================================== */

SELECT p.payment_type,
       COUNT(DISTINCT p.order_id)                                                   AS orders,
       ROUND(100.0 * SUM(p.payment_value) / SUM(SUM(p.payment_value)) OVER (), 1)   AS pct_of_value,
       ROUND(AVG(p.payment_value), 2)                                               AS avg_payment,
       ROUND(AVG(p.payment_installments), 1)                                        AS avg_installments
FROM stg_payments AS p
JOIN stg_orders   AS o ON o.order_id = p.order_id
WHERE o.is_delivered
  AND o.in_analysis_window
GROUP BY p.payment_type
ORDER BY orders DESC;


/* =====================================================================
   Step 2.8: Delivery performance

   Average and median delivery time, share of orders delivered after the
   promised date, and average gap between actual and estimated delivery
   (negative = delivered early). Measured per order for delivered orders
   in the analysis window.

   delivery_days and is_late were derived during the staging step, so
   delivery metrics use one consistent definition throughout.
   AVG(CASE WHEN ... THEN 1 ELSE 0 END) converts a true/false flag into
   a rate.
   ===================================================================== */

SELECT COUNT(*)                                                    AS delivered_orders,
       ROUND(AVG(delivery_days), 1)                                AS avg_delivery_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days)  AS median_delivery_days,
       ROUND(100.0 * AVG(CASE WHEN is_late THEN 1 ELSE 0 END), 1)  AS pct_late,
       ROUND(AVG(order_delivered_customer_date::date
                 - order_estimated_delivery_date::date), 1)        AS avg_days_vs_estimate
FROM stg_orders
WHERE is_delivered
  AND in_analysis_window
  AND delivery_days IS NOT NULL;


/* =====================================================================
   Step 2.9: Review score distribution

   Share of delivered orders in the analysis window by review score
   (1-5 stars). Establishes the baseline level of customer satisfaction
   before comparing scores against delivery performance.

   Uses stg_reviews, which holds one review per order after
   deduplication, so no order is counted twice.
   ===================================================================== */

SELECT r.review_score,
       COUNT(*)                                           AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_reviews
FROM stg_reviews AS r
JOIN stg_orders  AS o ON o.order_id = r.order_id
WHERE o.is_delivered
  AND o.in_analysis_window
GROUP BY r.review_score
ORDER BY r.review_score DESC;


/* =====================================================================
   Step 2.10: Review scores by delivery timeliness

   Compares customer satisfaction for orders delivered on time against
   orders delivered after the promised date: average review score and
   share of 1-2 star reviews. Tests the hypothesis that late delivery
   is a major driver of negative reviews.

   Orders without a delivery or estimated date (is_late IS NULL) are
   excluded, as their timeliness cannot be determined.
   ===================================================================== */

SELECT CASE WHEN o.is_late THEN 'Late' ELSE 'On time' END                      AS delivery,
       COUNT(*)                                                                AS orders,
       ROUND(AVG(r.review_score), 2)                                           AS avg_review,
       ROUND(100.0 * AVG(CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END), 1)  AS pct_1_or_2_stars
FROM stg_orders  AS o
JOIN stg_reviews AS r ON r.order_id = o.order_id
WHERE o.is_delivered
  AND o.in_analysis_window
  AND o.is_late IS NOT NULL
GROUP BY 1
ORDER BY 1;


/* =====================================================================
   Step 2.11: Top 15 product categories by revenue

   Revenue, orders, share of total revenue, average item price and
   freight as a percentage of price for the 15 highest-revenue
   categories. Shows how concentrated revenue is across the catalogue
   and which categories are costly to ship relative to their value,
   both inputs to the question of where to focus.
   ===================================================================== */

SELECT category,
       COUNT(DISTINCT order_id)                                AS orders,
       ROUND(SUM(price), 0)                                    AS revenue,
       ROUND(100.0 * SUM(price) / SUM(SUM(price)) OVER (), 1)  AS pct_of_revenue,
       ROUND(AVG(price), 2)                                    AS avg_item_price,
       ROUND(100.0 * SUM(freight_value) / SUM(price), 1)       AS freight_pct_of_price
FROM vw_sales_items
GROUP BY category
ORDER BY revenue DESC
LIMIT 15;


/* =====================================================================
   Step 2.12: Repeat customers

   Share of customers by number of delivered orders placed in the
   analysis window (1, 2, 3+). The repeat purchase rate is a key
   indicator of customer retention.

   Customers are identified by customer_unique_id (the person), since
   customer_id is generated per order and would make every customer
   appear to be a one-time buyer.
   ===================================================================== */

WITH customer_orders AS (
    SELECT customer_unique_id,
           COUNT(DISTINCT order_id) AS orders
    FROM vw_sales_items
    GROUP BY customer_unique_id
)
SELECT CASE WHEN orders = 1 THEN '1 order'
            WHEN orders = 2 THEN '2 orders'
            ELSE '3+ orders'
       END                                                 AS customer_type,
       COUNT(*)                                            AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_of_customers
FROM customer_orders
GROUP BY 1
ORDER BY 1;


/* =====================================================================
   Step 2.13: Customer and seller distribution by state (top 10)

   Number and share of customers and of active sellers in the ten
   states with the most customers. Compares where demand is (customers)
   with where supply is (sellers): the further apart they are, the
   higher the shipping cost and delivery time. A first look at
   geography ahead of the state and city revenue analysis in Phase 3.

   LEFT JOIN keeps every customer state even where no sellers are
   based; COALESCE shows those as 0 instead of NULL.
   ===================================================================== */

WITH cust AS (
    SELECT customer_state                     AS state,
           COUNT(DISTINCT customer_unique_id) AS customers
    FROM vw_sales_items
    GROUP BY customer_state
),
sell AS (
    SELECT seller_state              AS state,
           COUNT(DISTINCT seller_id) AS sellers
    FROM vw_sales_items
    GROUP BY seller_state
)
SELECT c.state,
       c.customers,
       ROUND(100.0 * c.customers / SUM(c.customers) OVER (), 1)                    AS pct_of_customers,
       COALESCE(s.sellers, 0)                                                      AS sellers,
       ROUND(100.0 * COALESCE(s.sellers, 0) / (SELECT SUM(sellers) FROM sell), 1)  AS pct_of_sellers
FROM cust AS c
LEFT JOIN sell AS s ON s.state = c.state
ORDER BY c.customers DESC
LIMIT 10;
