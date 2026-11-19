/* =====================================================================
   Olist E-commerce | ELT Step 0: Raw load check
   Database: PostgreSQL

   Purpose
   Confirm that every row in the 9 source CSV files reached the database
   before any cleaning starts. Import tools can skip rows silently,
   especially rows whose text contains commas or line breaks (such as
   review comments). A missing row would quietly distort every metric
   built later, so the load is reconciled first.

   Method
   1. List the imported tables and their columns, to confirm table names
      and the data types assigned on import.
   2. Compare each table's row count with the row count of its source
      CSV file. PASS = complete load. FAIL = rows missing; re-import.

   Expected row counts were taken from the source CSV files.
   ===================================================================== */

SET search_path TO public;

-- ---------------------------------------------------------------------
-- 1. Imported tables and their columns
-- ---------------------------------------------------------------------
SELECT table_name,
       string_agg(column_name || ' (' || data_type || ')', ', ' ORDER BY ordinal_position) AS columns
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY table_name
ORDER BY table_name;

-- ---------------------------------------------------------------------
-- 2. Row count reconciliation: database vs source CSV
-- ---------------------------------------------------------------------
SELECT table_name,
       actual_rows,
       expected_rows,
       CASE WHEN actual_rows = expected_rows THEN 'PASS' ELSE 'FAIL: re-import table' END AS status
FROM (
              SELECT 'customers'           AS table_name, (SELECT COUNT(*) FROM customers)           AS actual_rows,   99441 AS expected_rows
    UNION ALL SELECT 'orders',              (SELECT COUNT(*) FROM orders),              99441
    UNION ALL SELECT 'order_items',         (SELECT COUNT(*) FROM order_items),         112650
    UNION ALL SELECT 'order_payments',      (SELECT COUNT(*) FROM order_payments),      103886
    UNION ALL SELECT 'order_reviews',       (SELECT COUNT(*) FROM order_reviews),       99224
    UNION ALL SELECT 'products',            (SELECT COUNT(*) FROM products),            32951
    UNION ALL SELECT 'sellers',             (SELECT COUNT(*) FROM sellers),             3095
    UNION ALL SELECT 'product_category_translation', (SELECT COUNT(*) FROM product_category_translation), 71
) AS counts;


/* =====================================================================
   Re-import procedure for any table marked FAIL

   1. Empty the table, e.g.:  TRUNCATE TABLE order_reviews;
   2. pgAdmin: right-click the table > Import/Export Data > Import
      Options: Format = csv, Header = on, Delimiter = ,
               Quote = "  Escape = "  Encoding = UTF8
      (Format must be csv, not text, so quoted commas and line breaks
      inside review comments load correctly.)
   3. Re-run block 2.

   If a typed column rejects a value during import (for example an empty
   date), recreate the table with all columns as TEXT and import again.
   Step 1 converts every column to its proper type, so loading as text
   loses nothing.
   ===================================================================== */

/*
DROP TABLE IF EXISTS order_reviews;
CREATE TABLE order_reviews (
    review_id               TEXT,
    order_id                TEXT,
    review_score            TEXT,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TEXT,
    review_answer_timestamp TEXT
);
*/


/* =====================================================================
   Olist E-commerce | ELT Step 1: Build clean staging tables
   Database: PostgreSQL

   Purpose
   Transform the raw tables into clean, analysis-ready "staging" tables
   (prefix stg_). The raw tables are left untouched, so every cleaning
   decision is visible in this script and can be re-run at any time.

   Cleaning applied, and why
   - Data types: dates stored as timestamps and prices as numbers, so
     they can be summed, averaged and compared.
   - Blanks: empty strings converted to NULL, so missing values are
     treated consistently in every count.
   - Zip prefixes: padded back to 5 digits (leading zeros are lost on
     import), so zip codes match across tables.
   - Location names: cities in lower case, states in upper case. Seller
     cities stripped of suffixes such as "/sp" or "(porto seguro)", so
     one city is not counted as several.
   - Reviews: some orders have more than one review. Only the latest is
     kept, so those orders are not double-counted in review averages.
   - Products: misspelt columns renamed (lenght -> length), English
     category names added, the 2 untranslated categories translated
     manually, and products without a category labelled 'unknown' so
     they still count towards revenue.
   - Order flags: is_delivered, is_late, delivery_days and
     in_analysis_window (Jan 2017 - Aug 2018, the 20 complete months;
     the first and last months contain only a handful of orders).

   Every raw column is read as text first, so the script works whatever
   data type a column was given on import.
   Re-runnable: each staging table is dropped and rebuilt.
   ===================================================================== */

SET search_path TO public;

-- ---------------------------------------------------------------------
-- 1. Customers
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_customers;
CREATE TABLE stg_customers (
    customer_id              CHAR(32)     PRIMARY KEY,
    customer_unique_id       CHAR(32)     NOT NULL,
    customer_zip_code_prefix CHAR(5),
    customer_city            VARCHAR(100),
    customer_state           CHAR(2)
);

INSERT INTO stg_customers
SELECT TRIM(customer_id::text),
       TRIM(customer_unique_id::text),
       LPAD(TRIM(customer_zip_code_prefix::text), 5, '0'),
       LOWER(TRIM(customer_city::text)),
       UPPER(TRIM(customer_state::text))
FROM customers;

CREATE INDEX ix_customers_unique     ON stg_customers (customer_unique_id);
CREATE INDEX ix_customers_state_city ON stg_customers (customer_state, customer_city);

-- ---------------------------------------------------------------------
-- 2. Sellers
--    seller_city_raw keeps the original so the cleaning can be checked.
--    Cleaning: lower-case, cut at '/', '\', '(' or ' - ',
--    and set purely numeric or email-like "cities" to NULL.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_sellers;
CREATE TABLE stg_sellers (
    seller_id              CHAR(32)     PRIMARY KEY,
    seller_zip_code_prefix CHAR(5),
    seller_city            VARCHAR(100),
    seller_city_raw        VARCHAR(100),
    seller_state           CHAR(2)
);

INSERT INTO stg_sellers
SELECT TRIM(seller_id::text),
       LPAD(TRIM(seller_zip_code_prefix::text), 5, '0'),
       CASE
           WHEN TRIM(seller_city::text) ~ '^[0-9]+$' OR seller_city::text LIKE '%@%' THEN NULL
           ELSE TRIM(
                  split_part(
                    split_part(
                      split_part(
                        split_part(LOWER(TRIM(seller_city::text)), '/', 1),
                      '\', 1),
                    '(', 1),
                  ' - ', 1))
       END,
       TRIM(seller_city::text),
       UPPER(TRIM(seller_state::text))
FROM sellers;

CREATE INDEX ix_sellers_state_city ON stg_sellers (seller_state, seller_city);

-- ---------------------------------------------------------------------
-- 3. Orders (+ analysis flags)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_orders;
CREATE TABLE stg_orders (
    order_id                      CHAR(32)    PRIMARY KEY,
    customer_id                   CHAR(32)    NOT NULL,
    order_status                  VARCHAR(20) NOT NULL,
    order_purchase_timestamp      TIMESTAMP   NOT NULL,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP,
    purchase_month                DATE,        -- first day of the purchase month
    is_delivered                  BOOLEAN     NOT NULL,
    delivery_days                 INT,         -- purchase -> delivered to customer
    is_late                       BOOLEAN,     -- NULL when not delivered or no date
    in_analysis_window            BOOLEAN     NOT NULL  -- Jan 2017 – Aug 2018
);

INSERT INTO stg_orders
SELECT o.order_id,
       o.customer_id,
       o.order_status,
       o.purchase_ts,
       o.approved_at,
       o.delivered_carrier,
       o.delivered_customer,
       o.estimated_delivery,
       date_trunc('month', o.purchase_ts)::date,
       (o.order_status = 'delivered'),
       CASE WHEN o.order_status = 'delivered' AND o.delivered_customer IS NOT NULL
            THEN o.delivered_customer::date - o.purchase_ts::date END,
       CASE WHEN o.order_status = 'delivered' AND o.delivered_customer IS NOT NULL AND o.estimated_delivery IS NOT NULL
            THEN o.delivered_customer::date > o.estimated_delivery::date END,
       (o.purchase_ts >= '2017-01-01' AND o.purchase_ts < '2018-09-01')
FROM (
    SELECT TRIM(order_id::text)                                              AS order_id,
           TRIM(customer_id::text)                                           AS customer_id,
           LOWER(TRIM(order_status::text))                                   AS order_status,
           NULLIF(TRIM(order_purchase_timestamp::text), '')::timestamp       AS purchase_ts,
           NULLIF(TRIM(order_approved_at::text), '')::timestamp              AS approved_at,
           NULLIF(TRIM(order_delivered_carrier_date::text), '')::timestamp   AS delivered_carrier,
           NULLIF(TRIM(order_delivered_customer_date::text), '')::timestamp  AS delivered_customer,
           NULLIF(TRIM(order_estimated_delivery_date::text), '')::timestamp  AS estimated_delivery
    FROM orders
) AS o;

CREATE INDEX ix_orders_customer     ON stg_orders (customer_id);
CREATE INDEX ix_orders_status_month ON stg_orders (order_status, purchase_month);

-- ---------------------------------------------------------------------
-- 4. Order items
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_order_items;
CREATE TABLE stg_order_items (
    order_id            CHAR(32)      NOT NULL,
    order_item_id       INT           NOT NULL,
    product_id          CHAR(32)      NOT NULL,
    seller_id           CHAR(32)      NOT NULL,
    shipping_limit_date TIMESTAMP,
    price               NUMERIC(10,2) NOT NULL,
    freight_value       NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

INSERT INTO stg_order_items
SELECT TRIM(order_id::text),
       TRIM(order_item_id::text)::numeric::int,
       TRIM(product_id::text),
       TRIM(seller_id::text),
       NULLIF(TRIM(shipping_limit_date::text), '')::timestamp,
       TRIM(price::text)::numeric(10,2),
       TRIM(freight_value::text)::numeric(10,2)
FROM order_items;

CREATE INDEX ix_items_product ON stg_order_items (product_id);
CREATE INDEX ix_items_seller  ON stg_order_items (seller_id);

-- ---------------------------------------------------------------------
-- 5. Payments
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_payments;
CREATE TABLE stg_payments (
    order_id             CHAR(32)      NOT NULL,
    payment_sequential   INT           NOT NULL,
    payment_type         VARCHAR(20)   NOT NULL,
    payment_installments INT           NOT NULL,
    payment_value        NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

INSERT INTO stg_payments
SELECT TRIM(order_id::text),
       TRIM(payment_sequential::text)::numeric::int,
       LOWER(TRIM(payment_type::text)),
       TRIM(payment_installments::text)::numeric::int,
       TRIM(payment_value::text)::numeric(10,2)
FROM order_payments;

CREATE INDEX ix_payments_type ON stg_payments (payment_type);

-- ---------------------------------------------------------------------
-- 6. Reviews: one row per order (the most recently answered review)
--    raw_review_count keeps how many reviews the order originally had.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_reviews;
CREATE TABLE stg_reviews (
    order_id                CHAR(32) PRIMARY KEY,
    review_id               CHAR(32) NOT NULL,
    review_score            SMALLINT NOT NULL,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP,
    raw_review_count        INT      NOT NULL
);

INSERT INTO stg_reviews
SELECT order_id, review_id, review_score, review_comment_title, review_comment_message,
       review_creation_date, review_answer_timestamp, raw_review_count
FROM (
    SELECT r.*,
           COUNT(*)     OVER (PARTITION BY order_id) AS raw_review_count,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC NULLS LAST, review_id) AS rn
    FROM (
        SELECT TRIM(order_id::text)                                        AS order_id,
               TRIM(review_id::text)                                       AS review_id,
               TRIM(review_score::text)::numeric::smallint                 AS review_score,
               NULLIF(TRIM(review_comment_title::text), '')                AS review_comment_title,
               NULLIF(TRIM(review_comment_message::text), '')              AS review_comment_message,
               NULLIF(TRIM(review_creation_date::text), '')::timestamp     AS review_creation_date,
               NULLIF(TRIM(review_answer_timestamp::text), '')::timestamp  AS review_answer_timestamp
        FROM order_reviews
    ) AS r
) AS ranked
WHERE rn = 1;

CREATE INDEX ix_reviews_score ON stg_reviews (review_score);

-- ---------------------------------------------------------------------
-- 7. Category translation (+ the 2 categories Olist forgot to translate)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_category_translation;
CREATE TABLE stg_category_translation (
    product_category_name         VARCHAR(100) PRIMARY KEY,
    product_category_name_english VARCHAR(100) NOT NULL
);

INSERT INTO stg_category_translation
SELECT LOWER(TRIM(product_category_name::text)),
       LOWER(TRIM(product_category_name_english::text))
FROM product_category_translation;

INSERT INTO stg_category_translation VALUES
    ('pc_gamer', 'pc_gamer'),
    ('portateis_cozinha_e_preparadores_de_alimentos', 'portable_kitchen_and_food_preparers')
ON CONFLICT (product_category_name) DO NOTHING;

-- ---------------------------------------------------------------------
-- 8. Products (typos fixed, English category added)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_products;
CREATE TABLE stg_products (
    product_id                 CHAR(32)     PRIMARY KEY,
    product_category_name      VARCHAR(100),
    product_category_english   VARCHAR(100) NOT NULL,
    product_name_length        INT,
    product_description_length INT,
    product_photos_qty         INT,
    product_weight_g           INT,
    product_length_cm          INT,
    product_height_cm          INT,
    product_width_cm           INT
);

INSERT INTO stg_products
SELECT TRIM(p.product_id::text),
       NULLIF(LOWER(TRIM(p.product_category_name::text)), ''),
       COALESCE(t.product_category_name_english, 'unknown'),
       NULLIF(TRIM(p.product_name_lenght::text), '')::numeric::int,
       NULLIF(TRIM(p.product_description_lenght::text), '')::numeric::int,
       NULLIF(TRIM(p.product_photos_qty::text), '')::numeric::int,
       NULLIF(TRIM(p.product_weight_g::text), '')::numeric::int,
       NULLIF(TRIM(p.product_length_cm::text), '')::numeric::int,
       NULLIF(TRIM(p.product_height_cm::text), '')::numeric::int,
       NULLIF(TRIM(p.product_width_cm::text), '')::numeric::int
FROM products AS p
LEFT JOIN stg_category_translation AS t
       ON t.product_category_name = NULLIF(LOWER(TRIM(p.product_category_name::text)), '');

CREATE INDEX ix_products_category ON stg_products (product_category_english);

-- ---------------------------------------------------------------------
-- Done. Quick look at what was built:
-- ---------------------------------------------------------------------
          SELECT 'stg_customers'            AS table_name, COUNT(*) AS row_count FROM stg_customers
UNION ALL SELECT 'stg_sellers',              COUNT(*) FROM stg_sellers
UNION ALL SELECT 'stg_orders',               COUNT(*) FROM stg_orders
UNION ALL SELECT 'stg_order_items',          COUNT(*) FROM stg_order_items
UNION ALL SELECT 'stg_payments',             COUNT(*) FROM stg_payments
UNION ALL SELECT 'stg_reviews',              COUNT(*) FROM stg_reviews
UNION ALL SELECT 'stg_category_translation', COUNT(*) FROM stg_category_translation
UNION ALL SELECT 'stg_products',             COUNT(*) FROM stg_products;



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

/* =====================================================================
   Olist E-commerce | Phase 2: Exploratory Data Analysis
   Step 2.0: Reusable view of delivered sales

   Most EDA and business-analysis questions need the same base data:
   items from delivered orders in the analysis window (Jan 2017 -
   Aug 2018), joined to customer, seller and product details.

   Defining this once as a view keeps every metric on identical rules
   (delivered orders only, same date window, same joins), so results
   from different queries always reconcile. The Phase 3 analysis and
   the Power BI dataset reuse the same view.

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
   later breakdowns (by month, state, city, seller) are measured against.

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
   how many orders did not reach the customer (cancelled, unavailable,
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
    SELECT customer_state            AS state,
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


	/* =====================================================================
   Step 3.2: Service quality by state (Business question 1, continued)

   Revenue alone does not show how well, or how efficiently, each state
   is served. For every state this adds freight as a % of price, average
   delivery days, share of orders delivered late and average review.
   States combining low revenue with high freight, slow delivery and
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
    FROM stg_orders       AS o
    JOIN stg_customers    AS c ON c.customer_id = o.customer_id
    LEFT JOIN stg_reviews AS r ON r.order_id    = o.order_id
    WHERE o.is_delivered
      AND o.in_analysis_window
      AND o.delivery_days IS NOT NULL
    GROUP BY c.customer_state
)
SELECT RANK() OVER (ORDER BY i.revenue DESC)    AS revenue_rank,
       i.state_code,
       s.state_name,
       s.region,
       ROUND(i.revenue, 0)                      AS revenue,
       ROUND(100.0 * i.freight / i.revenue, 1)  AS freight_pct_of_price,
       ROUND(o.avg_delivery_days, 1)            AS avg_delivery_days,
       ROUND(100.0 * o.late_rate, 1)            AS pct_late,
       ROUND(o.avg_review, 2)                   AS avg_review
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
       ROUND(i.revenue, 0)                                         AS revenue,
       ROUND(100.0 * i.revenue   / SUM(i.revenue)   OVER (), 1)    AS pct_of_revenue,
       ROUND(100.0 * i.customers / SUM(i.customers) OVER (), 1)    AS pct_of_customers,
       ROUND(100.0 * COALESCE(sm.sellers, 0)
                   / (SELECT SUM(sellers) FROM seller_metrics), 1) AS pct_of_sellers,
       ROUND(i.revenue / i.orders, 2)                              AS avg_order_value,
       ROUND(100.0 * i.freight / i.revenue, 1)                     AS freight_pct_of_price,
       ROUND(o.avg_delivery_days, 1)                               AS avg_delivery_days,
       ROUND(100.0 * o.late_rate, 1)                               AS pct_late,
       ROUND(o.avg_review, 2)                                      AS avg_review
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
           COUNT(*)                                                            AS total_orders,
           COUNT(*) FILTER (WHERE is_delivered)                                AS delivered_orders,
           COUNT(*) FILTER (WHERE order_status IN ('canceled', 'unavailable')) AS lost_orders,
           AVG(CASE WHEN is_late THEN 1.0 ELSE 0.0 END)
               FILTER (WHERE is_delivered AND is_late IS NOT NULL)             AS late_rate,
           AVG(delivery_days) FILTER (WHERE is_delivered)                      AS avg_delivery_days,
           MIN(purchase_month)                                                 AS first_month,
           MAX(purchase_month)                                                 AS last_month
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

SELECT RANK() OVER (ORDER BY revenue DESC)                      AS revenue_rank,
       LEFT(seller_id, 8)                                       AS seller,
       seller_city,
       seller_state,
       delivered_orders,
       ROUND(revenue, 0)                                        AS revenue,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)         AS pct_of_revenue,
       avg_item_price,
       avg_review,
       pct_late,
       pct_lost,
       (SELECT COUNT(*) FROM vw_seller_scorecard)               AS sellers_in_scorecard,
       (SELECT ROUND(SUM(revenue), 0) FROM vw_seller_scorecard) AS total_revenue_check
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
       COUNT(*)                                                    AS sellers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_sellers,
       ROUND(SUM(revenue), 0)                                      AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)  AS pct_of_revenue,
       ROUND(SUM(revenue) / NULLIF(SUM(delivered_orders), 0), 2)   AS avg_order_value,
       ROUND(SUM(avg_review * reviewed_orders)
             / NULLIF(SUM(reviewed_orders), 0), 2)                 AS avg_review,
       ROUND(SUM(pct_late * delivered_orders)
             / NULLIF(SUM(delivered_orders), 0), 1)                AS pct_late,
       COUNT(*) FILTER (WHERE is_inactive)                         AS inactive_sellers
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
SELECT RANK() OVER (ORDER BY revenue DESC)                            AS revenue_rank,
       category,
       ROUND(revenue, 0)                                              AS revenue,
       ROUND(100.0 * revenue_outside_core / revenue, 1)               AS pct_revenue_outside_core,
       ROUND(100.0 * freight_ratio_core, 1)                           AS freight_pct_core,
       ROUND(100.0 * freight_ratio_outside, 1)                        AS freight_pct_outside_core,
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
FROM sales      AS s
JOIN service    AS sv ON sv.state_code = s.state_code
JOIN ref_states AS rs ON rs.state_code = s.state_code;



/* =====================================================================
   Step 3.10b: Strategy summary

   Revenue, share of revenue, late rate and review for each
   recommended strategy group, ordered by revenue. Late rate and review
   are weighted by revenue so larger states count proportionally.
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
       LEFT(seller_id, 8)                                      AS seller_short_id,
       seller_city,
       seller_state,
       seller_region,
       segment,
       CASE WHEN is_inactive THEN 'Inactive' ELSE 'Active' END AS activity_status,
       delivered_orders,
       revenue                                                 AS seller_revenue,
       avg_review                                              AS seller_avg_review,
       pct_late                                                AS seller_pct_late,
       pct_lost                                                AS seller_pct_lost
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

SELECT * FROM pbi_fact_sales;