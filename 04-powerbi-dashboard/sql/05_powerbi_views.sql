/* =====================================================================
   Olist E-commerce | Phase 4: Power BI dataset
   Database: PostgreSQL

   Purpose
   Shape the cleaned and analysed data into a star schema for Power BI:
   two fact tables (what happened) and two dimension tables (who/where).
   Power BI reads these views directly, so the dashboard uses exactly
   the same definitions as the SQL analysis and its totals reconcile
   (R$13,181,027 revenue, 96,211 delivered orders).

   Star schema
     pbi_fact_sales   one row per item sold        (revenue, freight, category)
     pbi_fact_orders  one row per delivered order  (delivery, lateness, review)
     pbi_dim_state    one row per state            (name, region, strategy)
     pbi_dim_seller   one row per seller           (location, segment, scorecard)
   A date table is created inside Power BI.

   The views carry no logic of their own beyond selecting and renaming:
   all business rules live in the Phase 1-3 views they read from.
   ===================================================================== */


/* =====================================================================
   Step 4.1a: Fact table: sales (item grain)
   ===================================================================== */

CREATE OR REPLACE VIEW pbi_fact_sales AS
SELECT order_id,
       order_item_id,
       order_purchase_timestamp::date AS purchase_date,
       customer_unique_id,
       INITCAP(customer_city)         AS customer_city,
       customer_state,
       seller_id,
       category,
       price,
       freight_value
FROM vw_sales_items;


/* =====================================================================
   Step 4.1b: Fact table: orders (order grain)
   Delivery and review metrics belong to the order, not the item, so
   they sit in a separate fact table to avoid double counting.
   ===================================================================== */

CREATE OR REPLACE VIEW pbi_fact_orders AS
SELECT o.order_id,
       o.order_purchase_timestamp::date               AS purchase_date,
       c.customer_unique_id,
       c.customer_state,
       o.delivery_days,
       CASE WHEN o.is_late THEN 1 WHEN o.is_late = FALSE THEN 0 END AS is_late,
       r.review_score,
       SUM(i.price)                                   AS order_revenue,
       SUM(i.freight_value)                           AS order_freight,
       COUNT(*)                                       AS items
FROM stg_orders       AS o
JOIN stg_customers    AS c ON c.customer_id = o.customer_id
JOIN stg_order_items  AS i ON i.order_id    = o.order_id
LEFT JOIN stg_reviews AS r ON r.order_id    = o.order_id
WHERE o.is_delivered
  AND o.in_analysis_window
GROUP BY o.order_id, o.order_purchase_timestamp, c.customer_unique_id,
         c.customer_state, o.delivery_days, o.is_late, r.review_score;


/* =====================================================================
   Step 4.1c: Dimension: states (with recommended strategy)
   ===================================================================== */

CREATE OR REPLACE VIEW pbi_dim_state AS
SELECT r.state_code,
       r.state_name,
       r.region,
       COALESCE(f.strategy, 'No sales') AS strategy
FROM ref_states          AS r
LEFT JOIN vw_state_focus AS f ON f.state_code = r.state_code;


/* =====================================================================
   Step 4.1d: Dimension: sellers (with segment and scorecard)
   ===================================================================== */

CREATE OR REPLACE VIEW pbi_dim_seller AS
SELECT seller_id,
       LEFT(seller_id, 8)                                    AS seller_short_id,
       seller_city,
       seller_state,
       seller_region,
       segment,
       CASE WHEN is_inactive THEN 'Inactive' ELSE 'Active' END AS activity_status,
       delivered_orders,
       revenue                                               AS seller_revenue,
       avg_review                                            AS seller_avg_review,
       pct_late                                              AS seller_pct_late,
       pct_lost                                              AS seller_pct_lost
FROM vw_seller_segments;


/* =====================================================================
   Step 4.1e: Check that the Power BI views reconcile
   Expected: revenue 13181027 in both facts, 96211 orders, 27 states,
   3068 sellers.
   ===================================================================== */

SELECT (SELECT ROUND(SUM(price), 0)         FROM pbi_fact_sales)  AS sales_revenue,
       (SELECT ROUND(SUM(order_revenue), 0) FROM pbi_fact_orders) AS orders_revenue,
       (SELECT COUNT(*)                     FROM pbi_fact_orders) AS orders,
       (SELECT COUNT(*)                     FROM pbi_dim_state)   AS states,
       (SELECT COUNT(*)                     FROM pbi_dim_seller)  AS sellers;
