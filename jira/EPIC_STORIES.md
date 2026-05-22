# Jira — Epic, Stories, Tasks

> **Convention:** Epic key `FIN`, stories `FIN-1xx`, tasks under each story `FIN-1xx.y`. Story points use Fibonacci (1, 2, 3, 5, 8, 13). Definition of Done at the end of this doc.

---

## EPIC: FIN-100 — Enterprise Financial Performance & Risk Analytics Platform

**Goal:** Deliver a production-shaped data platform that ingests financial source data via Fivetran into Snowflake, transforms it via dbt into governed marts, and surfaces revenue / risk / fraud analytics with full data-quality and PII controls.

**Business value:** unifies revenue, profitability, branch performance, fraud detection, and loan-portfolio analytics into a single warehouse — replacing six monthly spreadsheets and reducing fraud-flag latency from T+1 day to T+5 minutes.

**Success metrics:**
- Mart layer freshness ≤ 1 hour (95th-percentile).
- DQ pass rate ≥ 98 %.
- Zero PII exposure to BI_READER (verified by quarterly access review).
- Fraud-flag latency ≤ 5 min from transaction landing.

---

## STORY: FIN-101 — Snowflake foundation & RBAC (5 pts)

**As a** data platform engineer
**I want** a Snowflake account configured with isolated warehouses, schemas, and least-privilege roles
**So that** every downstream component runs in its own cost/security boundary.

### Tasks
- **FIN-101.1** Create database `FIN_ANALYTICS` and schemas `FIN_RAW`, `FIN_STG`, `FIN_INT`, `FIN_MART`, `FIN_AUDIT`, `GOVERNANCE`.
- **FIN-101.2** Provision three warehouses (`WH_FIN_INGEST`, `WH_FIN_TRANSFORM`, `WH_FIN_REPORTING`) — all XS, auto-suspend 60 s, auto-resume.
- **FIN-101.3** Create roles `FIN_ADMIN`, `FIVETRAN_LOADER`, `DBT_TRANSFORMER`, `BI_READER` and grant per least-privilege matrix.
- **FIN-101.4** Document role hierarchy in `SECURITY.md` and verify with a smoke-test query as each role.

### Acceptance criteria
- [ ] `SHOW WAREHOUSES` returns the three warehouses with `auto_suspend = 60`.
- [ ] `BI_READER` cannot `SELECT` from `FIN_RAW.RAW_CUSTOMERS` (expect `SQL access control error`).
- [ ] `DBT_TRANSFORMER` can `SELECT` from RAW and `CREATE` in STG/INT/MART.
- [ ] `FIVETRAN_LOADER` can `INSERT` into RAW but cannot `SELECT` (write-only).

---

## STORY: FIN-102 — Fivetran ingestion of 6 source files (3 pts)

**As a** data engineer
**I want** Fivetran to sync customers, accounts, transactions, loans, branches, and calendar from Google Sheets into Snowflake RAW
**So that** the warehouse always reflects the latest source-of-truth without manual exports.

### Tasks
- **FIN-102.1** Provision 6 Google Sheets connectors with naming convention `gsheet_fin_<entity>`.
- **FIN-102.2** Configure key-pair auth for Fivetran → Snowflake destination.
- **FIN-102.3** Set sync schedules: txn = 15 min, masters = 1 h, calendar = 24 h.
- **FIN-102.4** Validate row counts in RAW against source files; document in `FIVETRAN_SETUP.md`.

### Acceptance criteria
- [ ] All six connectors show `SYNCED` status with no warnings in Fivetran UI.
- [ ] RAW row counts match source files ± 0 rows.
- [ ] `_FIVETRAN_SYNCED` column populated on every row.
- [ ] Freshness DQ check `freshness_raw_transactions` passes (lag ≤ 120 min).

---

## STORY: FIN-103 — Staging layer (cleansing, dedup, surrogate keys) (5 pts)

**As a** data engineer
**I want** dbt staging models that cleanse, deduplicate, and stamp surrogate keys on every RAW table
**So that** intermediate and mart layers consume conformed data.

### Tasks
- **FIN-103.1** Implement `stg_*.sql` for customers, accounts, transactions, loans, branches, calendar.
- **FIN-103.2** Apply `generate_surrogate_key` from `dbt_utils` for natural-key MD5 hashes.
- **FIN-103.3** Add dedup via `QUALIFY ROW_NUMBER()` partitioned by natural key, ordered by `_FIVETRAN_SYNCED DESC`.
- **FIN-103.4** Author `_staging__models.yml` with `not_null`, `unique`, `accepted_values`, `relationships` tests.

### Acceptance criteria
- [ ] `dbt build --select staging` exits 0.
- [ ] `stg_customers` row count = distinct `CUSTOMER_ID` count in RAW (dedup works).
- [ ] `stg_transactions` has zero NULL `transaction_id` (filtered out).
- [ ] All `_staging__models.yml` tests pass except known orphan account (set to `severity: warn`).

---

## STORY: FIN-104 — Intermediate layer & FX conversion (3 pts)

**As a** data engineer
**I want** ephemeral intermediate models that enrich transactions with USD amounts and amortise loans
**So that** mart-layer aggregations are currency-normalised and tenure-aware.

### Tasks
- **FIN-104.1** Author `int_transactions_enriched.sql` joining txn × account × customer × branch × FX seed.
- **FIN-104.2** Author `int_loans_amortized.sql` computing `outstanding_balance_est` and `effective_months_paid`.
- **FIN-104.3** Seed `exchange_rates.csv` with USD/INR/EUR/GBP monthly rates for 2024–2026.

### Acceptance criteria
- [ ] Both intermediate models materialise as `ephemeral` (no physical table).
- [ ] `amount_usd` = `amount × exchange_rate_to_usd` for every row (audited via `assert_revenue_reconciles`).
- [ ] No row in `int_loans_amortized` has `outstanding_balance_est < 0`.

---

## STORY: FIN-105 — Mart layer: revenue + profitability + branch (8 pts)

**As a** finance analyst
**I want** mart tables for revenue, customer profitability, branch performance, and quarterly KPIs
**So that** I can answer revenue-by-segment-by-region questions in one query.

### Tasks
- **FIN-105.1** Build `dim_customer` with SCD-2 via `snap_customers` (segment/risk/region tracked).
- **FIN-105.2** Build `dim_account`, `dim_branch`, `dim_date`.
- **FIN-105.3** Build `fct_transactions` as incremental, clustered by `transaction_date`.
- **FIN-105.4** Build `fct_revenue_monthly`, `fct_customer_profitability`, `fct_branch_performance`, `fct_quarterly_kpis`.

### Acceptance criteria
- [ ] `fct_revenue_monthly` reconciles to `fct_transactions` within $0.01 (singular test passes).
- [ ] `fct_customer_profitability` populates `risk_value_segment` for every customer.
- [ ] QoQ growth in `fct_quarterly_kpis` matches hand-computed example for Q2-FY26.
- [ ] All mart `_models.yml` tests pass.

---

## STORY: FIN-106 — Risk & fraud marts (5 pts)

**As a** risk officer
**I want** `fct_loans`, `fct_loan_portfolio`, and `fct_fraud_indicators` tables
**So that** I can monitor default rates by segment and review fraud flags daily.

### Tasks
- **FIN-106.1** Build `fct_loans` and `fct_loan_portfolio` (default_rate_pct, NPA bucket).
- **FIN-106.2** Build `fct_fraud_indicators` with rapid-fire detection (3+ txns / 60 min) and `array_construct_compact` flag list.
- **FIN-106.3** Cross-check flagged rows against rules documented in `ARCHITECTURE.md`.

### Acceptance criteria
- [ ] Every blocked transaction in RAW appears in `fct_fraud_indicators`.
- [ ] Rapid-fire flag fires on the 3rd transaction within a 60-min window (verified by seeded test row).
- [ ] `default_rate_pct` matches `defaulted_loan_count / total_loan_count × 100` for each portfolio row.

---

## STORY: FIN-107 — Streams & Tasks for 5-min CDC fraud feed (5 pts)

**As a** fraud-ops engineer
**I want** a Snowflake stream + task pipeline that merges new transactions into a CDC sink every 5 minutes and flags suspicious patterns
**So that** fraud-flag latency drops from T+1 day (dbt cadence) to T+5 minutes.

### Tasks
- **FIN-107.1** Create `STG_TRANSACTIONS_INCR` clustered sink table.
- **FIN-107.2** Create `STR_RAW_TRANSACTIONS` stream over `RAW_TRANSACTIONS`.
- **FIN-107.3** Create root task `TSK_MERGE_STG_TRANSACTIONS` (5-min schedule, MERGE statement).
- **FIN-107.4** Create child task `TSK_FLAG_SUSPICIOUS_TXN` (AFTER parent) inserting into `FIN_AUDIT.SUSPICIOUS_TRANSACTIONS`.

### Acceptance criteria
- [ ] `SHOW TASKS` returns both tasks in `RESUMED` state.
- [ ] Inserting a new row into `RAW_TRANSACTIONS` causes a corresponding row in `STG_TRANSACTIONS_INCR` within 6 minutes.
- [ ] A test transaction matching high-value + blocked rules lands in `SUSPICIOUS_TRANSACTIONS` within 7 minutes.

---

## STORY: FIN-108 — Data quality framework (5 pts)

**As a** data platform engineer
**I want** a hourly DQ suite checking freshness, uniqueness, referential integrity, range, and volume
**So that** we detect pipeline issues before they corrupt marts.

### Tasks
- **FIN-108.1** Implement `SP_DQ_*` procedures across five categories.
- **FIN-108.2** Implement `SP_RUN_DQ_SUITE` master orchestrator and `TSK_DQ_VALIDATION` task.
- **FIN-108.3** Build `VW_DQ_LATEST`, `VW_DQ_FAILURES_OPEN`, `VW_DQ_SCORECARD`, `VW_LAYER_RECONCILIATION`.
- **FIN-108.4** Document framework in `DATA_QUALITY.md`.

### Acceptance criteria
- [ ] `CALL SP_RUN_DQ_SUITE()` populates `DQ_CHECK_RESULTS` with one row per check.
- [ ] `VW_DQ_FAILURES_OPEN` returns at most one row in steady-state (the known orphan WARN).
- [ ] Daily scorecard pass rate ≥ 98 %.

---

## STORY: FIN-109 — PII masking, RBAC, secure views (5 pts)

**As a** compliance officer
**I want** PII columns masked for non-admin roles, BI exposure restricted to SECURE views, and an access audit trail
**So that** the platform passes our pre-prod security review.

### Tasks
- **FIN-109.1** Create governance tags (`DATA_CLASS`, `PII_FIELD`) and apply to PII columns.
- **FIN-109.2** Create masking policies (`MASK_CUSTOMER_NAME`, `MASK_EMAIL`, `MASK_PHONE`, `MASK_GOVT_ID`).
- **FIN-109.3** Create SECURE views `VW_CUSTOMER_360`, `VW_FRAUD_DAILY`, `VW_REVENUE_EXEC`.
- **FIN-109.4** Author `GOVERNANCE.VW_ACCESS_AUDIT` over `QUERY_HISTORY`.

### Acceptance criteria
- [ ] Logged in as `BI_READER`, `SELECT customer_name FROM VW_CUSTOMER_360` returns initials only.
- [ ] `BI_READER` cannot `SELECT * FROM DIM_CUSTOMER` directly (no grant).
- [ ] `TAG_REFERENCES` query returns every `PII_LOW`/`PII_HIGH`/`FINANCIAL_SENSITIVE` column with a bound masking policy.

---

## STORY: FIN-110 — Documentation, dashboards, demo (3 pts)

**As a** project sponsor
**I want** a single `README.md`, dashboard specs, and a 30-min walkthrough
**So that** new joiners can ramp up in a day and reviewers can evaluate the deliverable.

### Tasks
- **FIN-110.1** Author top-level `README.md` (overview, setup, run order, tradeoffs).
- **FIN-110.2** Specify three dashboards in `dashboards/` (Executive, Fraud, Branch).
- **FIN-110.3** Prepare `presentation/WALKTHROUGH.md` with 30-min reviewer script.
- **FIN-110.4** Daily Slack stand-up template + blocker-escalation template.

### Acceptance criteria
- [ ] `README.md` lets a new engineer run `dbt build` end-to-end from a clean clone.
- [ ] Each dashboard spec lists tiles, source mart, refresh cadence, and target audience.
- [ ] Walkthrough script aligns to the 12-phase build narrative.

---

## Sprint plan (2-week sprints, 1 engineer @ 10 pts/sprint)

| Sprint | Stories                                 | Points | Theme                          |
|--------|-----------------------------------------|--------|--------------------------------|
| 1      | FIN-101, FIN-102, FIN-103               | 13     | Foundation + ingest + staging  |
| 2      | FIN-104, FIN-105                        | 11     | Intermediate + revenue marts   |
| 3      | FIN-106, FIN-107                        | 10     | Risk/fraud marts + Streams/Tasks |
| 4      | FIN-108, FIN-109, FIN-110               | 13     | DQ + Security + Docs/Demo      |

Total: 47 pts across 4 sprints (~8 weeks). One-engineer plan; with a pair, compress to 5 sprints / 5 weeks.

---

## Definition of Done

A story is **done** when:

1. All tasks are checked off.
2. All acceptance criteria pass.
3. Code reviewed via PR (≥ 1 approval).
4. `dbt build` succeeds end-to-end on `dev` target.
5. Relevant DQ checks pass.
6. Documentation updated (architecture / data-quality / security as applicable).
7. Demo recorded or shown in sprint review.
