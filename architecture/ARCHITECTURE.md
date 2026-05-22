# Architecture & Design — Enterprise Financial Performance & Risk Analytics Platform

> **Phase 1 deliverable.** This document describes the end-to-end target architecture,
> the rationale for each layer, the data-flow contract between systems, and the
> enterprise patterns enforced throughout the build.

---

## 1. Business context

A multinational financial-services company operates across four regions
(North America, EMEA, APAC, LATAM) and ~12 branches. Operational data is exported
nightly from booking, ledger, card-processing, and loan-management systems into
Google Sheets / CSV files maintained by regional ops teams. Finance leadership
needs a single, governed analytics layer to answer the following:

| Theme                | Example KPI                                        |
|----------------------|----------------------------------------------------|
| Revenue analytics    | Monthly revenue trend, revenue by segment / region |
| Customer profitability | LTV, top-N profitable customers, risk-vs-value matrix |
| Loan portfolio       | Outstanding balance, default rate, vintage analysis |
| Transaction analytics| Failed-txn %, high-value txns, fraud indicators    |
| Regional performance | Branch P&L, state-wise revenue, region growth %    |
| Financial KPIs       | Quarterly NIM, QoQ growth %, fee contribution %    |

---

## 2. Target architecture — logical view

```
+---------------------+      +------------+      +-------------------+
|  Google Sheets /    | ---> |  Fivetran  | ---> |   Snowflake RAW   |
|  CSV ops exports    |      |  connector |      |  (immutable land) |
+---------------------+      +------------+      +-------------------+
                                                          |
                                                          v
                                                 +-------------------+
                                                 |    STAGING        |
                                                 |  (clean, typed,   |
                                                 |   conformed)      |
                                                 +-------------------+
                                                          |
                                                          v
                                                 +-------------------+
                                                 |  INTERMEDIATE     |
                                                 |  (business logic, |
                                                 |   FX, joins)      |
                                                 +-------------------+
                                                          |
                                                          v
                                                 +-------------------+
                                                 |      MARTS        |
                                                 |  Star-schema      |
                                                 |  fact + dim       |
                                                 +-------------------+
                                                          |
                                                          v
                                                 +-------------------+
                                                 |  BI / Reporting   |
                                                 |  (Tableau /       |
                                                 |   Power BI /      |
                                                 |   Sigma)          |
                                                 +-------------------+
```

Snowflake **Streams + Tasks** sit alongside RAW → STAGING to provide CDC-style
micro-batch ingestion for transactions (the highest-volume table). dbt owns
STAGING → INTERMEDIATE → MARTS.

---

## 3. Medallion architecture — layer responsibilities

| Layer | Snowflake schema | Owner | Materialization | What it does | What it must NOT do |
|-------|------------------|-------|-----------------|--------------|---------------------|
| **RAW**        | `FIN_RAW`     | Fivetran / loaders | Tables (append) | 1:1 landed copy of source files. Original column names, original types, includes Fivetran metadata (`_FIVETRAN_SYNCED`, `_FIVETRAN_DELETED`). Immutable — no transforms. | No casting, no renaming, no joins, no DQ filtering. |
| **STAGING**    | `FIN_STG`     | dbt   | Views (default) | Rename to snake_case business terms, cast types, trim whitespace, normalize enums, deduplicate on natural key, attach surrogate hash keys. One staging model per source table. | No joins across sources, no business logic. |
| **INTERMEDIATE** | `FIN_INT`   | dbt   | Ephemeral / view | Re-usable transformations: FX normalization to USD, txn enrichment with account+customer attributes, loan amortization calcs. Not exposed to BI. | No reporting-shape aggregation. |
| **MARTS**      | `FIN_MART`    | dbt   | Tables / incremental | Star-schema dims and facts at well-defined grain. The contract for BI. | No source-specific column names. |

Why this split matters in finance:

- **RAW is immutable and auditable** — regulators (SOX, IFRS-9 expected loss models) require reproducibility of any reported figure. We can always re-derive any mart row from RAW.
- **STAGING is cheap to rebuild** (views) so schema drift from upstream Sheets is detected the moment a `dbt build` runs.
- **INTERMEDIATE isolates "how"** (FX rate logic, amortization formula) from "what" (fact_transactions). Changing the FX source means changing one model.
- **MARTS are the contract.** BI teams only query `FIN_MART.*`. Anything else is implementation detail.

---

## 4. Data flow contract

| # | Stage                       | Frequency       | Mechanism                                  | SLA  |
|---|-----------------------------|-----------------|--------------------------------------------|------|
| 1 | Ops exports CSV/Sheets      | Daily 22:00 UTC | Manual / scheduled Apps Script             | T+0  |
| 2 | Fivetran sync → RAW         | Every 6h        | Google Sheets connector + Snowflake dest.  | < 15 min after source change |
| 3 | RAW → STG via dbt run       | Hourly          | Airflow / dbt Cloud / Snowflake task       | < 5 min |
| 4 | STG → INT → MARTS           | Hourly          | dbt incremental for facts, full for dims   | < 10 min |
| 5 | dbt tests + DQ audit        | After every run | dbt test + custom audit table              | Hard gate before publish |
| 6 | BI refresh                  | Hourly          | Tableau extract / Sigma live               | < 2 min |

Total ingestion-to-insight target: **< 45 minutes**.

---

## 5. Incremental processing strategy

The two highest-volume tables — `transactions` and `loans` — are materialized
incrementally. Strategy:

- **`fct_transactions`** — `unique_key = transaction_sk`, `incremental_strategy = merge`. Filter on `transaction_timestamp >= (select max(transaction_timestamp) from {{ this }})` with a 24-hour overlap to absorb late-arriving rows.
- **`fct_loan_balances_daily`** — partitioned by `as_of_date`. Late-arriving disbursements trigger a backfill via the `dbt run --vars '{"backfill_from": "2025-01-01"}'` pattern.
- **Dimensions** — `dim_customer`, `dim_account` use a Type-2 SCD via `dbt snapshots` (see Phase 8) to preserve historical segment / risk-category changes — critical for vintage analysis.

---

## 6. Design decisions and trade-offs

| Decision | Chosen | Alternative considered | Why |
|----------|--------|------------------------|-----|
| Warehouse compute model | XS auto-suspend 60s | M always-on | Bootcamp/POC volume is < 5GB/day; XS is plenty, auto-suspend prevents bill creep. |
| Surrogate key generation | `dbt_utils.generate_surrogate_key` (MD5) | Snowflake sequences | Reproducible across environments, deterministic, no cross-env drift. |
| FX rates | Static seed (`exchange_rates.csv`) keyed by month | Live API | POC simplicity. Easy upgrade path: replace the seed with a `src_fx_rates` connector. |
| Type-2 SCDs | `dim_customer`, `dim_account` only | All dims | Risk segment / region changes drive vintage analysis; branches are stable. |
| Streams + Tasks vs only dbt | Both, for different jobs | Only dbt | Streams give true CDC on `transactions` for near-real-time fraud monitoring; dbt handles batch analytics. |
| dbt vs stored procedures | dbt | Snowflake SPs | Lineage, tests, docs, version control are first-class in dbt. |

---

## 7. Enterprise best practices enforced

1. **Naming conventions** — `RAW_<entity>`, `STG_<entity>`, `DIM_<entity>`, `FCT_<entity>`, `FCT_<entity>_<grain>` (e.g. `FCT_LOAN_BALANCES_DAILY`).
2. **Sources are declared once** in `sources.yml` — every staging model uses `{{ source(...) }}` so Fivetran schema drift breaks the build, not silently corrupts data.
3. **Every model is tested** — at minimum `unique` + `not_null` on the surrogate key. Facts also get `relationships` tests back to their dims.
4. **No SELECT \*** in marts. Explicit column lists protect downstream BI from upstream additions.
5. **All PII columns are tagged** in `schema.yml` with `meta.contains_pii: true` so the security model can apply masking via row-access / dynamic-data-masking policies.
6. **Materialization by layer**, not by guess — staging = view (cheap rebuild), marts = table or incremental (fast read).
7. **Code style** — leading commas, lowercase SQL keywords, CTE-first, no inline subqueries in marts.
8. **Lineage and docs** — `dbt docs generate` published as part of CI; reviewed in every PR.
9. **Cost control** — `query_tag` set per dbt invocation so Snowflake query history can be sliced by run.
10. **Reproducibility** — every artifact (manifest.json, run_results.json) archived to S3 / Bitbucket Pipelines artifacts.

---

## 8. Capacity & cost assumptions

| Item                  | Value          |
|-----------------------|----------------|
| Daily transaction rows  | ~5,000 (POC) → 5M (target) |
| Daily total ingest GB | < 1 GB (POC)   |
| Snowflake credits/day | < 5 (POC) / ~25 (target) |
| dbt run time          | < 4 minutes    |
| Storage 12 months     | < 50 GB        |

---

## 9. Out of scope (called out explicitly)

- Real-time streaming via Kafka / Snowpipe Streaming (would replace Fivetran).
- Machine-learning fraud scoring (the platform exposes the features; the model lives elsewhere).
- BI tool implementation (we deliver the gold-layer contract, not the dashboards themselves).
