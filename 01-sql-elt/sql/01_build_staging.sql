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
