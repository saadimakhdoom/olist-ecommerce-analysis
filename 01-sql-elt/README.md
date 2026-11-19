# Olist E-commerce: SQL ELT Pipeline (PostgreSQL)

Phase 1 of 3: **ELT** · [EDA](../02-sql-eda) · [Business analysis](../03-sql-analysis) · [Project overview](../README.md)

## What this project does

Loads the [Olist Brazilian E-commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (8 related tables, about 550,000 rows) into PostgreSQL, then transforms it into clean, typed, validated tables that the rest of the analysis is built on.

**ELT, not ETL:** the raw tables are loaded exactly as they arrive, and all cleaning happens inside the database in SQL. The raw data is never changed, so every cleaning step can be checked and repeated.

## Pipeline

| Step | Script | What it does |
|---|---|---|
| Extract + Load | `sql/00_check_raw_load.sql` | Checks every imported table against its CSV row count, with re-import steps for any table that comes up short |
| Transform | `sql/01_build_staging.sql` | Builds 8 `stg_*` tables with proper types, primary keys and indexes |
| Validate | `sql/02_validate_staging.sql` | 34 automated checks: row counts, orphans, missing values, valid ranges, payment reconciliation |

## Cleaning decisions

| Issue found | Decision |
|---|---|
| Review IDs not unique; some orders have 2+ reviews | Keep the latest review per order |
| 610 products with no category; 2 categories with no English name | Label `unknown`; translate the 2 by hand |
| Misspelt columns (`product_name_lenght`) | Renamed to `product_name_length` |
| Seller cities like `auriflama/sp`, `carapicuiba / sao paulo`, `04482255` | Strip the `/state` suffix; set invalid values to NULL; keep the original in `seller_city_raw` |
| Zip prefixes losing their leading zero | Padded back to 5 digits |
| Sparse months at the start and end (Sep–Dec 2016, Sep–Oct 2018) | `in_analysis_window` flag for Jan 2017 – Aug 2018 |
| `customer_id` changes with every order | `customer_unique_id` used for customer counts |

## Data model

```
stg_customers ──< stg_orders ──< stg_order_items >── stg_products >── stg_category_translation
                      │                 │
                      │                 └──> stg_sellers
                      ├──< stg_payments
                      └──── stg_reviews (one per order)
```

## Validation results

**34 checks, 0 failures:** 29 PASS (6 of them known source-data issues, counted and documented) and 5 INFO.

| Check group | Result |
|---|---|
| Row counts | All 8 staging tables match the source row counts. Reviews: 98,673 (one per order, after removing duplicates for 547 orders) |
| Referential integrity | 0 orphans: every item, payment and review links to a real order; every order to a customer; every item to a product and seller |
| Missing values | Only known gaps: 775 orders with no items, 8 delivered orders with no delivery date, 160 orders with no approval date, 610 products with no category |
| Valid values | No zero or negative prices, review scores all 1–5, all 27 Brazilian states present, no deliveries before purchase |
| Reconciliation | 249 of ~98,700 orders (0.25%) have payments differing from items + freight by more than R$1, consistent with instalment interest and vouchers |
| Totals | 96,211 delivered orders and R$13.18M revenue (Jan 2017 – Aug 2018); 96,096 unique customers |

## How to run

1. In PostgreSQL (pgAdmin 4), import 8 of the CSV files into the `public` schema as `customers`, `orders`, `order_items`, `order_payments`, `order_reviews`, `products`, `sellers` and `product_category_translation` (Import/Export Data, format csv, header on). The geolocation file is not used: maps are built from state and city names.
2. Run `00_check_raw_load.sql`, then `01_build_staging.sql`, then `02_validate_staging.sql`.

## Data source

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) on Kaggle, licensed CC BY-NC-SA 4.0. The 8 CSV files used are included in [`00-raw-data`](../00-raw-data).

## Skills shown

Data loading · data types and casting · string cleaning · window functions (`ROW_NUMBER`, `COUNT OVER`) · CTEs · primary keys and indexes · data validation and reconciliation · documenting cleaning decisions
