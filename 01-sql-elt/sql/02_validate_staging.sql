/* =====================================================================
   Olist E-commerce | ELT Step 2: Validate the staging tables
   Database: PostgreSQL

   Purpose
   Confirm the clean data can be trusted before any analysis is built
   on it. 34 automated checks in 6 groups:
   - Row counts:     nothing was lost during cleaning
   - Orphans:        every link between tables resolves (referential
                     integrity), e.g. every item belongs to a real order
   - Missing values: gaps appear only where expected
   - Valid values:   prices above zero, review scores 1-5, valid states
   - Reconciliation: amounts paid match item prices plus freight
   - Totals:         headline figures for the project summary

   Status meanings
   - PASS:               result matches the expected value
   - PASS (known issue): a documented issue in the source data, counted
                         and accounted for in the analysis
   - INFO:               reference figure, no pass/fail rule
   - FAIL:               result does not match; investigate before use
   ===================================================================== */

SET search_path TO public;

WITH checks (n, category, check_name, found, expected, rule_type) AS (

    -- 1. Row counts --------------------------------------------------
              SELECT 1, 'Row count', 'stg_orders rows', (SELECT COUNT(*) FROM stg_orders), 99441, 'equal'
    UNION ALL SELECT 2, 'Row count', 'stg_order_items rows', (SELECT COUNT(*) FROM stg_order_items), 112650, 'equal'
    UNION ALL SELECT 3, 'Row count', 'stg_payments rows', (SELECT COUNT(*) FROM stg_payments), 103886, 'equal'
    UNION ALL SELECT 4, 'Row count', 'stg_reviews rows (one per reviewed order)', (SELECT COUNT(*) FROM stg_reviews), 98673, 'equal'
    UNION ALL SELECT 5, 'Row count', 'stg_customers rows', (SELECT COUNT(*) FROM stg_customers), 99441, 'equal'
    UNION ALL SELECT 6, 'Row count', 'stg_sellers rows', (SELECT COUNT(*) FROM stg_sellers), 3095, 'equal'
    UNION ALL SELECT 7, 'Row count', 'stg_products rows', (SELECT COUNT(*) FROM stg_products), 32951, 'equal'
    UNION ALL SELECT 8, 'Row count', 'stg_category_translation rows (71 + 2 added)', (SELECT COUNT(*) FROM stg_category_translation), 73, 'equal'

    -- 2. Referential integrity (orphans) ------------------------------
    UNION ALL SELECT 10, 'Orphans', 'Items whose order is missing',
           (SELECT COUNT(*) FROM stg_order_items i WHERE NOT EXISTS (SELECT 1 FROM stg_orders o WHERE o.order_id = i.order_id)), 0, 'equal'
    UNION ALL SELECT 11, 'Orphans', 'Items whose product is missing',
           (SELECT COUNT(*) FROM stg_order_items i WHERE NOT EXISTS (SELECT 1 FROM stg_products p WHERE p.product_id = i.product_id)), 0, 'equal'
    UNION ALL SELECT 12, 'Orphans', 'Items whose seller is missing',
           (SELECT COUNT(*) FROM stg_order_items i WHERE NOT EXISTS (SELECT 1 FROM stg_sellers s WHERE s.seller_id = i.seller_id)), 0, 'equal'
    UNION ALL SELECT 13, 'Orphans', 'Orders whose customer is missing',
           (SELECT COUNT(*) FROM stg_orders o WHERE NOT EXISTS (SELECT 1 FROM stg_customers c WHERE c.customer_id = o.customer_id)), 0, 'equal'
    UNION ALL SELECT 14, 'Orphans', 'Payments whose order is missing',
           (SELECT COUNT(*) FROM stg_payments p WHERE NOT EXISTS (SELECT 1 FROM stg_orders o WHERE o.order_id = p.order_id)), 0, 'equal'
    UNION ALL SELECT 15, 'Orphans', 'Reviews whose order is missing',
           (SELECT COUNT(*) FROM stg_reviews r WHERE NOT EXISTS (SELECT 1 FROM stg_orders o WHERE o.order_id = r.order_id)), 0, 'equal'
    UNION ALL SELECT 16, 'Orphans', 'Orders with no items (known issue)',
           (SELECT COUNT(*) FROM stg_orders o WHERE NOT EXISTS (SELECT 1 FROM stg_order_items i WHERE i.order_id = o.order_id)), 775, 'known'

    -- 3. Missing values ----------------------------------------------
    UNION ALL SELECT 20, 'Missing values', 'Orders with no purchase date',
           (SELECT COUNT(*) FROM stg_orders WHERE order_purchase_timestamp IS NULL), 0, 'equal'
    UNION ALL SELECT 21, 'Missing values', 'Delivered orders with no delivery date (known issue)',
           (SELECT COUNT(*) FROM stg_orders WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL), 8, 'known'
    UNION ALL SELECT 22, 'Missing values', 'Orders with no approval date (known issue)',
           (SELECT COUNT(*) FROM stg_orders WHERE order_approved_at IS NULL), 160, 'known'
    UNION ALL SELECT 23, 'Missing values', 'Products with no category (labelled unknown)',
           (SELECT COUNT(*) FROM stg_products WHERE product_category_name IS NULL), 610, 'known'
    UNION ALL SELECT 24, 'Missing values', 'Products with a category but no English name',
           (SELECT COUNT(*) FROM stg_products WHERE product_category_name IS NOT NULL AND product_category_english = 'unknown'), 0, 'equal'
    UNION ALL SELECT 25, 'Missing values', 'Sellers with an invalid city (set to NULL)',
           (SELECT COUNT(*) FROM stg_sellers WHERE seller_city IS NULL), NULL, 'info'

    -- 4. Valid values and ranges --------------------------------------
    UNION ALL SELECT 30, 'Valid values', 'Items with price <= 0',
           (SELECT COUNT(*) FROM stg_order_items WHERE price <= 0), 0, 'equal'
    UNION ALL SELECT 31, 'Valid values', 'Items with negative freight',
           (SELECT COUNT(*) FROM stg_order_items WHERE freight_value < 0), 0, 'equal'
    UNION ALL SELECT 32, 'Valid values', 'Review scores outside 1-5',
           (SELECT COUNT(*) FROM stg_reviews WHERE review_score NOT BETWEEN 1 AND 5), 0, 'equal'
    UNION ALL SELECT 33, 'Valid values', 'States that are not 2 capital letters',
           (SELECT COUNT(*) FROM stg_customers WHERE customer_state !~ '^[A-Z]{2}$')
         + (SELECT COUNT(*) FROM stg_sellers   WHERE seller_state   !~ '^[A-Z]{2}$'), 0, 'equal'
    UNION ALL SELECT 34, 'Valid values', 'Distinct customer states (Brazil has 27)',
           (SELECT COUNT(DISTINCT customer_state) FROM stg_customers), 27, 'equal'
    UNION ALL SELECT 35, 'Valid values', 'Delivered before purchase (impossible)',
           (SELECT COUNT(*) FROM stg_orders WHERE order_delivered_customer_date < order_purchase_timestamp), 0, 'equal'
    UNION ALL SELECT 36, 'Valid values', 'Payments of 0 (known issue)',
           (SELECT COUNT(*) FROM stg_payments WHERE payment_value = 0), 9, 'known'
    UNION ALL SELECT 37, 'Valid values', 'Payment type not_defined (known issue)',
           (SELECT COUNT(*) FROM stg_payments WHERE payment_type = 'not_defined'), 3, 'known'
    UNION ALL SELECT 38, 'Valid values', 'Orders that had more than one review (deduplicated)',
           (SELECT COUNT(*) FROM stg_reviews WHERE raw_review_count > 1), NULL, 'info'

    -- 5. Reconciliation: payments vs items ----------------------------
    --    Payments include instalment interest, so small gaps are normal.
    UNION ALL SELECT 40, 'Reconciliation', 'Orders where payments differ from items + freight by > R$1',
           (SELECT COUNT(*) FROM (
                SELECT i.order_id
                FROM (SELECT order_id, SUM(price + freight_value) AS item_total FROM stg_order_items GROUP BY order_id) AS i
                JOIN (SELECT order_id, SUM(payment_value) AS paid FROM stg_payments GROUP BY order_id) AS p
                  ON p.order_id = i.order_id
                WHERE ABS(p.paid - i.item_total) > 1
            ) AS gaps), NULL, 'info'

    -- 6. Totals for the README ----------------------------------------
    UNION ALL SELECT 50, 'Totals', 'Delivered orders in analysis window (Jan 2017 - Aug 2018)',
           (SELECT COUNT(*) FROM stg_orders WHERE is_delivered AND in_analysis_window), NULL, 'info'
    UNION ALL SELECT 51, 'Totals', 'Revenue R$ (delivered, analysis window)',
           (SELECT ROUND(SUM(i.price), 0) FROM stg_order_items i JOIN stg_orders o ON o.order_id = i.order_id
            WHERE o.is_delivered AND o.in_analysis_window), NULL, 'info'
    UNION ALL SELECT 52, 'Totals', 'Unique customers (customer_unique_id)',
           (SELECT COUNT(DISTINCT customer_unique_id) FROM stg_customers), 96096, 'equal'
)
SELECT n           AS check_no,
       category,
       check_name,
       found,
       expected,
       CASE
           WHEN rule_type = 'info'  THEN 'INFO'
           WHEN rule_type = 'known' AND found = expected THEN 'PASS (known issue, documented)'
           WHEN found = expected THEN 'PASS'
           ELSE 'FAIL'
       END AS status
FROM checks
ORDER BY n;
