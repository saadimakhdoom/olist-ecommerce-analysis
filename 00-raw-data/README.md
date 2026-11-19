# Raw data

The source files used in this project, unchanged from the original download.

**Source:** [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (Kaggle)
**Licence:** [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). Shared here for non-commercial, educational use with credit to Olist.

| File | Loaded as table | Rows |
|---|---|---|
| olist_customers_dataset.csv | customers | 99,441 |
| olist_orders_dataset.csv | orders | 99,441 |
| olist_order_items_dataset.csv | order_items | 112,650 |
| olist_order_payments_dataset.csv | order_payments | 103,886 |
| olist_order_reviews_dataset.csv | order_reviews | 99,224 |
| olist_products_dataset.csv | products | 32,951 |
| olist_sellers_dataset.csv | sellers | 3,095 |
| product_category_name_translation.csv | product_category_translation | 71 |

The geolocation file from the original dataset was not used and is not included.

Row counts are verified after loading by [`01-sql-elt/sql/00_check_raw_load.sql`](../01-sql-elt/sql/00_check_raw_load.sql).

[← Back to project overview](../README.md)
