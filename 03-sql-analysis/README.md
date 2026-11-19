# Phase 3: Business Analysis

Answering four business questions for Olist, a Brazilian e-commerce marketplace, using PostgreSQL.

**Script:** [`sql/04_business_analysis.sql`](sql/04_business_analysis.sql), 11 steps (3.0–3.10).
**Scope:** delivered orders, Jan 2017 – Aug 2018, R$13.18M revenue. Revenue = item price (excludes freight).

> **Limitation:** the dataset contains no product cost or seller margin data, so profit cannot be calculated. Seller performance is measured with a scorecard (revenue, reviews, late delivery, lost orders, freight) instead.

---

## Q1. Which states bring in the most revenue?

**Revenue is highly concentrated.** São Paulo alone generates **38.4%**. Seven of 27 states produce **81.5%**, and the bottom 17 states only 12%.

| Region | Revenue | % revenue | % customers | % sellers | Late | Review |
|---|---:|---:|---:|---:|---:|---:|
| Southeast | R$8.62M | 65.4% | 68.5% | 73.7% | 6.1% | 4.18 |
| South | R$1.90M | 14.4% | 14.3% | 21.7% | 5.9% | 4.19 |
| Northeast | R$1.49M | 11.3% | 9.4% | **1.8%** | **12.8%** | **3.97** |
| Centre-West | R$0.84M | 6.4% | 5.8% | 2.6% | 6.5% | 4.13 |
| North | R$0.33M | 2.5% | 1.9% | 0.1% | 8.6% | 4.03 |

- **Freight and delivery time rise with distance from São Paulo:** from 13.9% of price and 8.7 days in SP to about 25% and 20–30 days in the North.
- **Reviews track lateness, not speed.** North states wait 20–30 days but are rarely late and rate 4.2+. Northeast states are slow *and* often late (17–22% in Alagoas and Maranhão) and score lowest.
- **Remote customers spend more per order** (R$218 in Paraíba vs R$125 in São Paulo): cheap items are rarely worth the shipping.
- **Rio de Janeiro is an outlier:** the #2 state (13.3% of revenue) with a 12.1% late rate, nearly 3x São Paulo's.

## Q2. Which cities are the top performers?

- **São Paulo (14.1%) and Rio de Janeiro (7.2%)** generate over a fifth of revenue. The **top 20 cities make 40%**; the remaining 60% is spread across thousands of cities.
- **Greater São Paulo** (São Paulo, Guarulhos, São Bernardo do Campo, Santo André, Osasco) = **17.2%** of revenue.
- Outside the Southeast, demand sits in **regional capitals**: Brasília (#4), Curitiba (#5), Porto Alegre (#7), Salvador (#8), Fortaleza (#14), Recife (#16).
- **Growth (Jan–Aug 2017 vs 2018, Olist overall +141%):** 16 of the top 20 cities outgrew the business, led by **Santos (+329%)** and **Recife (+251%)**. **Rio de Janeiro grew only +108%**, and its share of São Paulo + Rio revenue fell from 38% to 30%. Rio and Salvador, the two slowest-growing large cities, both sit in states with about 12% late rates, a link worth investigating.

## Q3. Which sellers are underperforming?

Every seller was scored and placed in one segment (minimum 10 delivered orders to be judged):

| Segment | Sellers | % sellers | Revenue | % revenue | Review | Late |
|---|---:|---:|---:|---:|---:|---:|
| Star (top 20% by revenue) | 221 | 7.2% | R$7.84M | **59.5%** | 4.13 | 6.8% |
| Solid | 881 | 28.7% | R$3.38M | 25.6% | 4.21 | 5.1% |
| Long tail (<10 orders) | 1,834 | **59.8%** | R$1.21M | **9.2%** | 4.19 | 6.8% |
| **At risk** (review <3.5 or >15% late) | 132 | 4.3% | **R$0.76M** | 5.8% | **3.60** | **17.4%** |

- **7% of sellers generate 60% of revenue.** No single seller is critical: the largest is 1.7%.
- **132 at-risk sellers hold R$759K** of revenue with a 17.4% late rate. The largest is only R$39K, so intervening carries little revenue risk. Late delivery is the main issue for 11 of the 15 largest.
- **Seller churn is high:** 1,246 sellers (41%) made no sales after May 2018, most of them from the long tail.
- A **Bahia-based seller ranks #2 overall** with only a 3.4% late rate, which shows local Northeast sellers can perform strongly.

## Q4. Should Olist focus instead of selling everything everywhere?

**Yes: focus differently by region and by category.**

| Strategy | States | % revenue | Late | Review |
|---|---|---:|---:|---:|
| **Protect & grow** | SP, MG, RS, PR, SC | **64.5%** | 4.8% | 4.23 |
| **Fix delivery** | RJ, ES | 15.3% | **11.9%** | 3.98 |
| **Develop local supply** | 9 Northeast states | 11.3% | **12.8%** | 3.97 |
| **Maintain** | DF, GO, MT, MS | 6.4% | 6.6% | 4.13 |
| **Selective** | 7 North states | 2.5% | 8.7% | 4.03 |

**Categories that travel well:** watches & gifts keep freight at **11.5%** outside the core and already earn 24% of their revenue there; health & beauty and auto behave similarly.
**Categories that don't:** office furniture freight jumps from 22% to **37%** outside the core; bed/bath/table earns only **12%** of its revenue outside the core (vs 20% overall).

*Strategy rules (thresholds and groupings) were defined from these findings and would be refined with the business.*

---

## Recommendations

1. **Protect the core (SP, MG and the South, 64.5% of revenue).** Prioritise Star sellers (7% of sellers, 60% of revenue) with account management and visibility, and concentrate bulky categories (furniture, housewares, bed/bath) here, where freight is lowest.
2. **Fix delivery in Rio de Janeiro and Espírito Santo (15.3% of revenue, 11.9% late).** Late orders are about 7x more likely to receive a 1–2 star review. As an illustration, bringing RJ/ES to the core's 4.8% late rate would mean about 1,000 fewer late orders and about 540 fewer negative reviews.
3. **Develop local supply in the Northeast (11.3% of revenue, only 1.8% of sellers).** Recruit sellers starting in Salvador, Recife and Fortaleza, where Northeast demand concentrates. A Bahia-based seller already ranks #2 nationally.
4. **Be selective in the North (2.5% of revenue).** Promote light, high-value categories (watches & gifts, health & beauty, telephony) rather than bulky items.
5. **Act on at-risk sellers (R$759K, 132 sellers).** Logistics support where lateness is the issue, quality review where reviews are poor, and reduced visibility if there's no improvement.
6. **Set more accurate delivery estimates and A/B test them.** Orders arrive about 12 days earlier than promised; reliability, not raw speed, drives reviews.

## SQL techniques used
Reference (dimension) table · views for reusable logic · multiple CTEs at different grains · window functions (`RANK`, `NTILE`, running `SUM() OVER`) · `FILTER (WHERE ...)` for period and segment comparisons · weighted averages · `CASE`-based segmentation and business rules · reconciliation checks against validated totals
