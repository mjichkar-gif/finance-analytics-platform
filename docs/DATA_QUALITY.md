# Data Quality Framework

## Overview

The platform runs a **defence-in-depth** DQ strategy: every layer has its own checks, and failures at any layer halt downstream propagation.

```
RAW   →  freshness, volume, schema drift (Fivetran-level + SP_DQ_*)
STG   →  uniqueness, FK, range, dedup-residue (dbt tests + SP_DQ_*)
MART  →  business invariants, reconciliation, drift (dbt tests + singular tests)
```

## Two engines, one truth

| Engine                          | Cadence              | Coverage                                       | Failure mode |
|---------------------------------|----------------------|------------------------------------------------|--------------|
| **Snowflake DQ procs** (`FIN_AUDIT.SP_RUN_DQ_SUITE`) | Hourly via `TSK_DQ_VALIDATION` | RAW + STG layers, infra-level (freshness, volume, FK) | Logged to `DQ_CHECK_RESULTS`, alerted via `VW_DQ_FAILURES_OPEN` |
| **dbt tests** (`dbt test`)      | Per CI run + scheduled hourly | STG + MART columns, business invariants     | dbt run fails → CI blocks merge; scheduled run logged to `FIN_AUDIT.DBT_RUN_RESULTS` |

These are complementary, not redundant. The Snowflake suite catches issues *between* dbt runs (e.g. a Fivetran outage at 03:17); dbt catches issues *introduced by* a transformation.

## Check categories

### 1. Freshness
- **What:** how stale is the most recent row vs `CURRENT_TIMESTAMP`?
- **Why:** silent Fivetran failure is the most common production incident.
- **Thresholds:** transactions ≤ 120 min (ERROR), masters ≤ 1440 min (WARN).

### 2. Uniqueness
- RAW layer logs duplicates as INFO (expected — STG deduplicates).
- STG layer treats duplicates as ERROR (dedup logic must produce a unique grain).

### 3. Referential integrity
- Transactions → accounts: ERROR if any orphan (must never happen).
- Accounts → customers: WARN with tolerance ≤ 5 (one known orphan in POC seed; tightens to 0 in prod).

### 4. Value range
- Transaction amount > 0 (sign goes in `transaction_direction`).
- Transaction timestamp ≤ now.
- Loan interest rate in [0, 30] %.

### 5. Volume
- Yesterday's row count must be within ±70 % of the 7-day rolling average.
- Detects both pipeline outages (zero rows) and floods (duplicate full-loads).

## Operationalising failures

Three views drive alerting and dashboards:

| View | Purpose | Refresh |
|------|---------|---------|
| `VW_DQ_LATEST` | One row per check, most recent execution | On query |
| `VW_DQ_FAILURES_OPEN` | All currently failing checks, sorted by severity | On query — primary alert source |
| `VW_DQ_SCORECARD` | 30-day pass-rate roll-up by layer/category | On query — dashboard tile |

A separate `VW_LAYER_RECONCILIATION` compares RAW vs STG row counts per entity and flags drift > 5 %.

## How to add a new check

1. Add a new `INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS …` statement inside the relevant `SP_DQ_*_CHECKS` procedure (or create a new one and call it from `SP_RUN_DQ_SUITE`).
2. Pick a unique `CHECK_NAME` (lowercase, snake_case).
3. Choose severity:
   - `ERROR` — blocks downstream marts; pages on-call.
   - `WARN` — logged + Slack notification, no paging.
   - `INFO` — logged only, surfaces in scorecard.
4. Add a `CHECK_DETAILS` string describing what the check enforces and what action to take on breach.

## How to add a dbt test

Prefer generic tests in `_models.yml`; reach for singular tests in `tests/` only for cross-model invariants (e.g. `assert_revenue_reconciles.sql`).

```yaml
- name: amount_usd
  tests:
    - not_null
    - dbt_expectations.expect_column_values_to_be_between:
        min_value: 0
        max_value: 10000000
        severity: error
```

## Alerting wiring (out of scope for the POC, documented for reviewers)

`VW_DQ_FAILURES_OPEN` → Snowflake notification integration → Slack channel `#fin-dq-alerts`. Each ERROR row triggers a PagerDuty incident routed to the on-call DE.

## Known POC compromises

- **One orphan account** by design (FK to `C99999`) — exercises the WARN path on `fk_accounts_to_customers` without failing the build.
- **Volume check** needs ≥ 7 days of history; first week of operation it returns PASS by default (`rolling_avg IS NULL`).
- **Schema-drift detection** uses `INFORMATION_SCHEMA.COLUMNS` snapshots; the implementation is sketched but out of scope for the bootcamp deliverable.
