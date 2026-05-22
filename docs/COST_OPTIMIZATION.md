# Cost Optimization

Snowflake bills on compute (warehouse-seconds) and storage (TB-months). Storage at this scale is rounding error — every meaningful optimization is on the compute side.

## Levers we pulled

### 1. Three warehouses, all XS, auto-suspend 60 s

| Warehouse           | Workload                | Why XS                                              |
|---------------------|-------------------------|-----------------------------------------------------|
| `WH_FIN_INGEST`     | Fivetran COPY INTO RAW  | COPY is I/O-bound, not CPU; XS handles 100 MB/sec   |
| `WH_FIN_TRANSFORM`  | dbt builds + DQ procs   | Models are small (≤ 1k rows × 6 tables); XS is correct sizing |
| `WH_FIN_REPORTING`  | BI queries              | Single-user POC; in prod, switch to multi-cluster XS auto-scale |

Three warehouses, not one, because each gives independent cost attribution: a `query_history` filter by `warehouse_name` is the cleanest "where is my Snowflake bill going" lens. Combining them would mean parsing query_tags forever.

**Auto-suspend at 60 s** vs the default 600 s saves 9× per idle minute. Snowflake's minimum billable interval is 60 s, so this is the floor that doesn't churn warm-cache hits.

### 2. `query_tag` on every dbt invocation

Set in `macros/set_query_tag.sql`:

```
project=finance_analytics target=dev invocation_id=abc-123 user=aditi
```

This makes `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` filterable: cost-per-environment, cost-per-engineer, cost-per-dbt-run. Without it, the bill is one bucket and tuning is guessing.

### 3. Materialization choices

| Layer        | Strategy        | Why                                                            |
|--------------|-----------------|----------------------------------------------------------------|
| Staging      | `view`          | Tiny logic; views avoid storage + materialise-time cost        |
| Intermediate | `ephemeral`     | CTEs inlined into downstream models — no table, no scheduling  |
| Marts        | `table`         | Predictable read latency for BI                                |
| `fct_transactions` | `incremental` (merge) | Largest fact; incremental wins above ~100k rows         |

### 4. Clustering on `transaction_date`

Both `RAW_TRANSACTIONS` and `fct_transactions` cluster by `transaction_date`. BI queries almost always filter by a date range; clustering lets Snowflake prune micro-partitions and skip > 90 % of scans for typical "last month" queries.

We did **not** cluster `dim_customer` (too small to benefit) or `fct_loan_portfolio` (already aggregated; full scans are cheap).

### 5. Result-caching exploited deliberately

`fct_revenue_monthly` is rebuilt hourly but BI queries against it hit the result cache for 24 h unless the underlying data changes. We do not run `ALTER TABLE … SUSPEND_RECLUSTER` cycles that would invalidate the cache on a schedule.

### 6. Stream + Task vs. continuous polling

Streams + Tasks pull deltas only; a naive "poll the source every minute" pattern would do full table scans. Streams keep an offset cursor — cost scales with *change volume*, not *table size*.

## What costs we accepted

**Three warehouses instead of one.** Two extra cold-start auto-resume events per hour. Bill impact: cents per day at XS. The cost-attribution benefit is worth it.

**Incremental overlap of 24 h.** Re-scans 24 h of data each run instead of the strict cutoff. Bill impact: maybe 5 × what a strict cutoff would scan. The data-correctness benefit is worth it.

**`dbt_expectations` macros compile to CTE-heavy SQL.** Slightly more elaborate query plans than handwritten tests. Worth it for the wider test surface area; tunable later if it shows up in `query_history`.

## What we'd tune next

| Action                                                            | Expected save | Effort |
|-------------------------------------------------------------------|---------------|--------|
| Move `dbt build` from on-demand to a scheduled task at off-peak   | 10–20 %       | 0.5 d  |
| Replace `dbt snapshot` strategy with `merge` on a hashable digest | 5 %           | 1 d    |
| Add Snowflake **resource monitors** with daily credit caps        | n/a — safety  | 0.25 d |
| Switch `WH_FIN_REPORTING` to multi-cluster XS on contention       | conc-dependent| 0.5 d  |
| Tag PII queries — they show up disproportionately in cost; cache  | 5 %           | 1 d    |

## Resource monitor — production-only safety net

```sql
CREATE OR REPLACE RESOURCE MONITOR RM_FIN_DAILY
    CREDIT_QUOTA  = 50
    FREQUENCY     = DAILY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_FIN_INGEST     SET RESOURCE_MONITOR = RM_FIN_DAILY;
ALTER WAREHOUSE WH_FIN_TRANSFORM  SET RESOURCE_MONITOR = RM_FIN_DAILY;
ALTER WAREHOUSE WH_FIN_REPORTING  SET RESOURCE_MONITOR = RM_FIN_DAILY;
```

Not in `01_account_setup.sql` because the credit quota depends on the account's actual contract. Documented here for the production checklist.

## Observability for cost

Two views to add (next sprint):

```sql
-- Cost-per-dbt-invocation
CREATE VIEW VW_DBT_RUN_COST AS
SELECT
    query_tag,
    SUM(credits_used_cloud_services + credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_tag LIKE 'project=finance_analytics%'
GROUP BY 1;

-- Cost-per-mart
CREATE VIEW VW_MART_COST AS
SELECT
    REGEXP_SUBSTR(query_text, 'INTO\\s+(\\S+)', 1, 1, 'i', 1) AS target_object,
    SUM(execution_time) / 1000 AS exec_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_type = 'CREATE_TABLE_AS_SELECT'
GROUP BY 1;
```
