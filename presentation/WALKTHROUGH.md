# Reviewer Walkthrough — 30-minute Script

A working session, not a slide read. Open three windows side-by-side: the repo tree, Snowflake worksheet, dbt docs.

| Time   | Section                              | Show / Say                                                     |
|--------|--------------------------------------|----------------------------------------------------------------|
| 0:00 – 2:00 | Frame the problem               | Pre-existing pain: 6 spreadsheets, manual fraud review at T+1 day, no PII discipline. One-line goal. |
| 2:00 – 6:00 | Architecture                    | Whiteboard the medallion: RAW → STG → INT → MART. Why three warehouses. Why both Streams/Tasks AND dbt. |
| 6:00 – 10:00 | Source & ingest                | Open `data/raw/`, show the 6 CSVs. Walk `FIVETRAN_SETUP.md` quickly. Mention deliberate dirty data. |
| 10:00 – 14:00 | dbt walk                      | `dbt docs serve`; lineage tour: pick `fct_revenue_monthly`, click upstream to source. Show 1 test. |
| 14:00 – 18:00 | Streams/Tasks demo            | In Snowflake: insert a high-value blocked transaction into RAW. Wait 5 min. Show it landed in `SUSPICIOUS_TRANSACTIONS`. |
| 18:00 – 22:00 | DQ + Security                  | `SELECT * FROM VW_DQ_FAILURES_OPEN` (one warn row, the known orphan). Switch role to `BI_READER`. `SELECT customer_name FROM VW_CUSTOMER_360 LIMIT 3` — initials only. |
| 22:00 – 26:00 | Tradeoffs                      | The four decisions that took longest (see below). What I'd do with more time. |
| 26:00 – 30:00 | Q & A                          | Anticipated questions below. |

---

## Architecture talking points (3 anchors, ~90 s each)

1. **Why MD5 surrogate keys.** Joins survive natural-key changes; deterministic across envs (dev/ci/prod hash identically); no integer-sequence contention; small storage penalty.

2. **Why two transformation engines.**
   - **Streams + Tasks** for the 5-min fraud detection feed. Operational, latency-bound, narrow scope.
   - **dbt** for hourly analytics marts. Tested, version-controlled, lineage-aware, broad scope.
   Different SLAs → different tools. Trying to do fraud-flagging in dbt would force a 5-min `dbt run` schedule, which is wasteful and fragile.

3. **Why SCD-2 only on customer and account dimensions.** Branches barely change; calendar never does; date never does. SCD-2 on stable dimensions is just storage cost with no analytic value. We're disciplined about where we pay.

---

## The four tradeoffs I expect questions on

### 1. Incremental vs full-refresh on `fct_transactions`
- **Chose:** incremental with a 24-hour late-arrival overlap.
- **Why:** transactions can land late (network blips, batch retries). Without overlap, late rows would be permanently missed. Picked 24h via the `txn_late_arrival_overlap_hours` var; production might raise to 72h.
- **Cost:** more rows scanned per run. Tradeoff worth it for completeness.

### 2. dbt seeds for FX rates
- **Chose:** seed CSV.
- **Why:** simple, version-controlled, fine for monthly rates.
- **Limit:** stale rates risk if seed is not updated. Production path: replace seed with a Fivetran connector for an FX API + nightly task to refresh a `dim_fx_rate` table.
- I called this out in `ARCHITECTURE.md` rather than over-engineering for the POC.

### 3. Masking policies vs full row-access policies
- **Chose:** column masking + sketch of row-access (`RAP_REGION_SCOPE` declared but not bound).
- **Why:** masking gives 80 % of the value (BI_READER cannot reconstruct identities) without the complexity of a user→region mapping table. Row-access is one `ALTER` away when the production org chart is ready.

### 4. The known orphan account
- **Kept deliberately.** Exercises the WARN path on the `fk_accounts_to_customers` test and the `VW_DQ_FAILURES_OPEN` view. Reviewers see a real-shaped DQ workflow rather than a too-clean dataset.

---

## Anticipated reviewer questions + answers

**Q: Why XS warehouses everywhere?**
A: Data volume is tiny (1k txn rows). XS is correct for the scale; the right-sizing pattern is documented in `ARCHITECTURE.md` — `WH_FIN_REPORTING` would scale up to M with multi-cluster auto-scaling under real BI concurrency.

**Q: What happens if Fivetran double-loads a file?**
A: STG dedup via `QUALIFY ROW_NUMBER() PARTITION BY natural_key ORDER BY _FIVETRAN_SYNCED DESC` keeps the latest. The `uniqueness_raw_customer_id` DQ check logs the duplicate as INFO so we know it happened; the mart sees one row.

**Q: How do you handle late-arriving dimensions?**
A: Two ways. (1) Snapshots: `snap_customers` catches SCD-2 changes whenever they appear, even days late, because the check strategy compares incoming attributes against current state. (2) `fct_transactions` references `dim_customer` by surrogate key; if a transaction lands before its customer dimension row, the FK is NULL — caught by `fk_transactions_to_accounts` DQ check.

**Q: Why dbt_expectations on top of dbt's builtin tests?**
A: Builtin tests cover existence/cardinality. `dbt_expectations` covers value ranges, regex shapes, and distributional checks. The two are complementary; using both adds 30 lines of YAML and dramatically widens the test coverage.

**Q: Where would you spend the next sprint?**
A: Three things, in order:
1. Wire `RAP_REGION_SCOPE` and seed a `user_region` mapping table.
2. Replace the FX seed with a real connector + nightly refresh.
3. Add a `dim_product` and a `fct_product_revenue` mart — product is the missing analytic axis (current marts roll up to segment/region but not product).

**Q: What did you cut?**
A: A `dim_employee` and branch-staffing fact, a fraud-investigation outcome table, and BI tool integration. All called out as out-of-scope in `ARCHITECTURE.md`.

**Q: Production readiness — what blocks ship?**
A: Three things. (1) Real Fivetran source (Sheets is POC-only; needs a database connector or REST connector). (2) Secret management — `profiles.example.yml` uses env_vars; production must use a vault. (3) Alert wiring — `VW_DQ_FAILURES_OPEN` → Slack → PagerDuty integration is documented but not built.

---

## Backup demos (if time allows)

- **Lineage diff.** `dbt run --select state:modified+ --state ./prod-manifest` showing only changed-downstream models.
- **Cost attribution.** `query_history` filtered by `query_tag` showing per-environment, per-invocation cost.
- **dbt-docs `--no-compile`.** Faster doc generation pattern.
