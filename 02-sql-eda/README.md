# Phase 2: Exploratory Data Analysis (EDA)

Exploring the cleaned Olist data in PostgreSQL to understand the business before answering the main questions: size, growth, seasonality, basket size, payments, delivery, customer satisfaction, product mix, retention and geography.

**Script:** [`sql/03_eda.sql`](sql/03_eda.sql), 14 steps (2.0–2.13), each a single query.
**Scope:** delivered orders, Jan 2017 – Aug 2018. Revenue = item price (excludes freight). Customer = `customer_unique_id`.

## Headline numbers

| Metric | Value |
|---|---:|
| Revenue | **R$13.18M** |
| Delivered orders | 96,211 |
| Customers | 93,104 |
| Active sellers | 2,945 |
| Average order value | R$137 |
| Items per order | 1.14 |
| Freight | R$2.19M (16.6% of revenue) |

## Key findings

**1. Fast growth, driven by new customers rather than bigger orders**
Revenue grew **141% year on year** (Jan–Aug 2018: R$7.22M vs Jan–Aug 2017: R$2.99M), while average order value stayed flat at R$124–149. Growth plateaued in 2018 at around R$830K–980K a month. The last months may be understated, since orders placed close to the data extract date may not yet have been delivered.

**2. Black Friday is the single biggest sales event**
24 Nov 2017 produced **1,147 orders, about 5x a normal day**. The Black Friday to Cyber Monday period (24–28 Nov) delivered **35% of November's revenue in 5 days**. Outside Black Friday, the busiest days cluster on Mondays.

**3. Customers buy one cheap item and don't come back**
- **90%** of orders contain a single item
- The median item costs **R$75** (the mean of R$120 is inflated by a few expensive items)
- Only **3.0%** of customers made a repeat purchase

**4. Shipping weighs heavily on cheaper items**
Freight is fairly flat (median R$16), so it adds about **a third** to the cost of a R$40 item. Freight ranges from **8% of price** (watches & gifts) to **25%** (office furniture).

**5. Late delivery is strongly associated with negative reviews**
| Delivery | Orders | Avg review | 1–2 star reviews |
|---|---:|---:|---:|
| On time | 89,182 | 4.29 | 9.2% |
| Late | 6,378 | **2.27** | **62.4%** |

Late orders are 7% of reviewed orders but about **one third of all negative reviews**. Overall satisfaction is 4.16/5, with a J-shaped distribution: 1-star reviews (9.7%) outnumber 2-star reviews (3.1%) threefold.

**6. Delivery estimates are very conservative**
Median delivery is **10 days** and 6.8% of orders arrive late, but orders arrive **11.8 days earlier than promised** on average. Cautious estimates keep the late rate low but may deter customers at checkout.

**7. Revenue is concentrated in a core set of categories**
The top 15 of 74 categories generate **76% of revenue**, and the largest (health & beauty) is only 9.3%: concentrated, but not dependent on a single category.

**8. Supply is concentrated in São Paulo; demand is spread out**
São Paulo has **42% of customers but 60% of sellers**. The Southeast and South hold 83% of customers and 95% of sellers. States such as Bahia (3.4% of customers, 0.6% of sellers) are supplied from far away, which is likely to raise freight and delivery times. This is tested in Phase 3.

## Other observations
- 97% of all orders were delivered; 1.2% were lost (canceled or unavailable). Half of the losses were "unavailable": paid orders where the seller had no stock.
- Credit cards account for 78.5% of payment value, with 3.5 instalments on average. Boleto serves about 1 in 5 orders, and vouchers are only 2.2% of value.

## Questions carried into Phase 3
- Which states and cities generate the most revenue, and how efficiently (freight, delivery, reviews)?
- Are late deliveries and high freight concentrated in particular regions or categories?
- Which sellers underperform on revenue, reviews, lateness and cancellations?
- Where should Olist focus to grow revenue?

## SQL techniques used
Views · CTEs · window functions (`LAG`, `SUM() OVER`) · percentiles (`PERCENTILE_CONT`) · `CASE` expressions · `LEFT JOIN` with `COALESCE` · conditional aggregation for rates
