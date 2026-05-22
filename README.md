# Enterprise Financial Performance & Risk Analytics Platform

End-to-end data platform for a retail bank: ingests customer / account / transaction / loan / branch / calendar data via Fivetran into Snowflake, transforms it through a four-layer medallion (RAW → STG → INT → MART) using dbt, and surfaces governed marts for revenue, profitability, branch performance, fraud detection, and loan-portfolio risk — with a parallel 5-minute Streams/Tasks pipeline for low-latency fraud flags.

Built as the capstone deliverable for the **phData Associate Data Engineer Bootcamp**, domain: **Finance**.

---

## At a glance

| Aspect              | Choice                                                                 |
|---------------------|------------------------------------------------------------------------|
| Source              | 6 Google Sheets (customers, accounts, transactions, loans, branches, calendar) |
| Ingest              | Fivetran (15-min for txn, hourly masters, 24h calendar)                |
| Warehouse           | Snowflake (3 warehouses for cost isolation: ingest / transform / report) |
| Modelling           | dbt 1.8 — medallion (`FIN_RAW` → `FIN_STG` → `FIN_INT` → `FIN_MART`)   |
| Low-latency path    | Snowflake Streams + Tasks (5-min CDC into a fraud-detection sink)      |
| DQ                  | Hourly Snowflake-procedure suite + dbt tests (incl. `dbt_expectations`) |
| Governance          | Tag-based dynamic data masking + SECURE views + role-scoped RBAC       |
| Currency            | Reporting in USD via seeded FX rates (USD/INR/EUR/GBP, monthly)        |
| Fiscal year         | April – March (Q1 = Apr-Jun)                                            |
| Reporting role      | `BI_READER` (mart-views only, PII masked)                              |

---

## Repository layout

```
finance-analytics-platform/
├── architecture/
│   ├── ARCHITECTURE.md           ← medallion design, SLAs, design decisions
│   └── DATA_MODEL.md             ← star schema, grains, SCD-2 rules
├── data/
│   ├── generate_sample_data.py   ← seedable CSV generator (deterministic)
│   └── raw/                      ← generated CSVs (6 entities, ~1000 rows)
├── snowflake/
│   ├── 01_setup/                 ← warehouses, schemas, roles, RAW tables, bootstrap load
│   ├── 02_streams_tasks/         ← RAW→STG transforms + Streams/Tasks pipeline
│   ├── 03_security/              ← masking policies, RBAC hardening, SECURE views
│   └── 04_dq/                    ← DQ validation suite + orchestration + monitoring views
├── dbt/
│   └── finance_analytics/        ← full dbt project (staging, intermediate, marts, snapshots, tests, macros, seeds)
├── docs/
│   ├── FIVETRAN_SETUP.md         ← connector setup runbook
│   ├── DATA_QUALITY.md           ← DQ framework reference
│   └── SECURITY.md               ← governance, PII, RBAC
├── jira/
│   ├── EPIC_STORIES.md           ← epic, 10 stories, 40 tasks, sprint plan
│   └── STANDUP_AND_ESCALATION.md ← daily templates
├── bitbucket/
│   ├── BRANCHING_STRATEGY.md     ← branching, commit, PR rules
│   └── pull_request_template.md
├── dashboards/
│   └── DASHBOARD_SPECS.md        ← 3 dashboard specifications
├── presentation/
│   ├── WALKTHROUGH.md            ← 30-min reviewer script
│   └── LEARNINGS.md              ← one-page retrospective
└── README.md                      ← this file
```

---

## Setup — running it end-to-end

### Prerequisites

- Snowflake account (any edition; Enterprise unlocks dynamic data masking — the security layer assumes it)
- Python 3.10+
- dbt-snowflake 1.8+
- Optional: Fivetran trial account (the bootstrap load uses local `COPY INTO` so Fivetran is not strictly required to demo)

### One-time

```bash
# 1. Generate sample data (idempotent; seed=42 → deterministic outputs)
cd data
python generate_sample_data.py
ls raw/  # 6 CSVs

# 2. Bootstrap Snowflake (run as ACCOUNTADMIN once)
snowsql -f snowflake/01_setup/01_account_setup.sql
snowsql -f snowflake/01_setup/02_raw_tables.sql
snowsql -f snowflake/01_setup/03_bootstrap_load.sql  # PUT + COPY of the 6 CSVs

# 3. Streams & Tasks (5-min fraud pipeline)
snowsql -f snowflake/02_streams_tasks/01_raw_to_staging_transforms.sql
snowsql -f snowflake/02_streams_tasks/02_streams_and_tasks.sql

# 4. Security
snowsql -f snowflake/03_security/01_pii_masking.sql
snowsql -f snowflake/03_security/02_rbac_and_secure_views.sql

# 5. DQ framework
snowsql -f snowflake/04_dq/01_dq_validation_suite.sql
snowsql -f snowflake/04_dq/02_dq_orchestration.sql
```

### dbt

```bash
cd dbt/finance_analytics
cp profiles.example.yml ~/.dbt/profiles.yml   # then edit creds
dbt deps                                       # install dbt_utils + dbt_expectations
dbt seed                                       # load exchange_rates.csv
dbt build --target dev                         # builds + tests everything
dbt snapshot                                   # SCD-2 captures
dbt docs generate && dbt docs serve            # lineage UI on http://localhost:8080
```

### Smoke tests

```sql
-- as DBT_TRANSFORMER
SELECT COUNT(*) FROM FIN_ANALYTICS.FIN_MART.FCT_TRANSACTIONS;        -- ~800
SELECT COUNT(*) FROM FIN_ANALYTICS.FIN_MART.DIM_CUSTOMER WHERE is_current = TRUE;  -- ~80
SELECT * FROM FIN_ANALYTICS.FIN_AUDIT.VW_DQ_FAILURES_OPEN;            -- ≤ 1 row (known orphan WARN)

-- as BI_READER
SELECT customer_name FROM FIN_ANALYTICS.FIN_MART.VW_CUSTOMER_360 LIMIT 5;
-- → initials only (e.g. 'J. S.')
```

---

## Run order (idempotent)

The whole platform refreshes on three cadences:

| Cadence | What runs                                                                 | Trigger                       |
|---------|---------------------------------------------------------------------------|-------------------------------|
| 5 min   | `TSK_MERGE_STG_TRANSACTIONS` + `TSK_FLAG_SUSPICIOUS_TXN`                  | Snowflake task scheduler      |
| 60 min  | `TSK_DQ_VALIDATION` + `dbt build --target prod`                           | Snowflake task + Airflow/CI   |
| 24 h    | `dbt snapshot` + FX-rate refresh (when wired)                              | Scheduled job                 |

---

## Documents to read, in order

1. **`architecture/ARCHITECTURE.md`** — the design decisions and tradeoffs.
2. **`architecture/DATA_MODEL.md`** — the star schema and grains.
3. **`docs/FIVETRAN_SETUP.md`** — ingest setup.
4. **`docs/DATA_QUALITY.md`** — DQ framework.
5. **`docs/SECURITY.md`** — governance and PII.
6. **`jira/EPIC_STORIES.md`** — the project plan in Jira form.
7. **`bitbucket/BRANCHING_STRATEGY.md`** — how code lands.
8. **`presentation/WALKTHROUGH.md`** — the 30-min reviewer script.

---

## Design highlights (the four worth defending)

1. **Two transformation engines.** Streams/Tasks for fraud (latency); dbt for analytics (testability). Different SLAs justify different tools. See walkthrough Q&A.

2. **Tag-based dynamic data masking.** One policy per data class, bound via Snowflake tags. Survives column renames. Auditable via `TAG_REFERENCES`.

3. **MD5 surrogate keys.** Deterministic across environments; joins survive natural-key changes; no sequence contention.

4. **24-hour late-arrival overlap on `fct_transactions`.** Parameterised in `dbt_project.yml` so production can tune. Earlier version lost late-landing rows.

---

## Known POC compromises

- **One orphan account** (FK to `C99999`) by design — exercises the WARN path on `fk_accounts_to_customers`.
- **FX seed** instead of live API connector — documented upgrade path in `ARCHITECTURE.md`.
- **Row-access policy declared but not bound** — pattern shown in `03_security/01_pii_masking.sql`; binding requires a `user_region` mapping table.
- **`STATEMENT_TIMEOUT_IN_SECONDS` set on a template user only** — production rollout binds to every BI user via a script.
- **No Airflow / dbt Cloud scheduler in repo** — `dbt build` is shown as manual; production uses one of those (Bitbucket pipeline sketch is in `BRANCHING_STRATEGY.md`).

---

## Future improvements

| Priority | Item                                                            | Effort  |
|----------|-----------------------------------------------------------------|---------|
| P1       | Replace FX seed with API-connector + nightly task               | 1 day   |
| P1       | Wire `RAP_REGION_SCOPE` + populate `user_region`                | 0.5 day |
| P1       | Slack + PagerDuty wiring for `VW_DQ_FAILURES_OPEN`              | 1 day   |
| P2       | Add `dim_product` + `fct_product_revenue` mart                  | 2 days  |
| P2       | dbt-Cloud or Airflow scheduler with retries + SLAs              | 2 days  |
| P3       | BYOK / Tri-Secret Secure for key management                     | 1 week  |
| P3       | Real-time stream processing (Snowflake Streaming + sub-min mart)| 1 week  |

---

## Credit

- **Domain:** retail banking / consumer finance.
- **Pattern source:** medallion architecture (Databricks coinage, applies to Snowflake equally).
- **dbt packages:** `dbt-labs/dbt_utils`, `calogica/dbt_expectations`.
- **Built by:** a phData bootcamp engineer, May 2026.

---

## License & data

All sample data is synthetic, generated by `data/generate_sample_data.py` with seed 42. No real customer, account, or transaction data is in this repo.
