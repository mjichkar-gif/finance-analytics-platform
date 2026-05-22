# Dashboard Specifications

Three dashboards, each backed by **one mart view** and consumed by **one persona**. We do not build the dashboards (out of scope for the bootcamp) — we specify them so the BI team can implement against a stable contract.

Recommended tool: any of Looker / Tableau / Power BI / Sigma / Hex. The marts are tool-agnostic.

---

## Dashboard 1 — Executive Revenue & Growth

**Audience:** CFO, COO, head of retail banking
**Source:** `FIN_ANALYTICS.FIN_MART.VW_REVENUE_EXEC` (SECURE view over `fct_revenue_monthly`)
**Refresh:** hourly (driven by `WH_FIN_REPORTING`)
**Role required:** `BI_READER`

### Tiles

| # | Tile                             | Visualisation        | Measure                                         | Slice/filter        |
|---|----------------------------------|----------------------|-------------------------------------------------|---------------------|
| 1 | Headline revenue (current FYTD)  | Big number + delta   | `SUM(revenue_usd)` vs same period last FY       | FY toggle           |
| 2 | Revenue trend                    | Line, 24 months      | `SUM(revenue_usd)` by `revenue_month`           | Segment, region     |
| 3 | Revenue by segment               | Stacked bar          | `SUM(revenue_usd)` by segment × month           | Region              |
| 4 | Revenue by region                | Map (lat/lng from branch) | `SUM(revenue_usd)` by region                | Quarter             |
| 5 | QoQ growth                       | Bar with reference   | `qoq_growth_pct` from `fct_quarterly_kpis`      | Segment             |
| 6 | Active customers                 | Line                 | `SUM(active_customer_count)` by month           | Segment             |
| 7 | Revenue per active customer      | KPI tile             | `revenue / active_customers`                    | —                   |

### Interactions
- Cross-filter: clicking a segment in tile 3 filters tiles 2, 5, 6, 7.
- Drill-through from any tile → opens "Customer 360" with the filtered segment.

### Acceptance test
The headline revenue tile must equal the result of `SELECT SUM(revenue_usd) FROM VW_REVENUE_EXEC WHERE revenue_month >= DATE_TRUNC('year', current_date)`. Mismatch by more than $0.01 fails acceptance.

---

## Dashboard 2 — Fraud Operations

**Audience:** fraud-ops team, AML compliance
**Source:** `FIN_ANALYTICS.FIN_MART.VW_FRAUD_DAILY` (aggregated SECURE view) + drill-through to `FIN_AUDIT.SUSPICIOUS_TRANSACTIONS` (gated by `FIN_ADMIN`)
**Refresh:** 5 min (driven by Streams/Tasks pipeline)
**Role required:** `DBT_TRANSFORMER` for aggregates, `FIN_ADMIN` for row-level drill

### Tiles

| # | Tile                              | Visualisation     | Measure                                          | Notes              |
|---|-----------------------------------|-------------------|--------------------------------------------------|--------------------|
| 1 | Open flags today                  | Big number        | `COUNT(*)` from suspicious_transactions WHERE flagged_at >= current_date | Refresh 5 min      |
| 2 | Flag latency (P50 / P95)          | KPI               | DATEDIFF txn_timestamp → flagged_at              | SLO: P95 < 5 min   |
| 3 | Flagged amount by rule            | Donut             | `SUM(flagged_amount_usd)` by rule                | Last 7 days        |
| 4 | Flag volume trend                 | Line, 30 days     | `SUM(flagged_count)` by day                      | Stacked by rule    |
| 5 | High-risk customer leaderboard    | Table             | top 20 customers by flagged_amount_usd in 30d    | Drill to detail    |
| 6 | Region heatmap                    | Map               | `SUM(flagged_count)` by region                   | —                  |
| 7 | Rule outcome funnel               | Bar               | flagged → investigated → confirmed → blocked     | weekly             |

### Interactions
- Tile 5 row click → drill-through to per-customer flag detail (FIN_ADMIN only; logged in audit view).
- Tile 4 segment click → filters tile 7 funnel by rule.

### Acceptance test
The "flagged count today" must match `SELECT COUNT(*) FROM FIN_AUDIT.SUSPICIOUS_TRANSACTIONS WHERE flagged_at::DATE = current_date`.

---

## Dashboard 3 — Branch Performance

**Audience:** regional managers, branch managers
**Source:** `FIN_ANALYTICS.FIN_MART.FCT_BRANCH_PERFORMANCE` (joined to `dim_branch`)
**Refresh:** hourly
**Role required:** `BI_READER` (row-access policy scopes to assigned region when bound)

### Tiles

| # | Tile                          | Visualisation       | Measure                                                       |
|---|-------------------------------|---------------------|---------------------------------------------------------------|
| 1 | Branch league table           | Sortable table      | revenue_usd, customer_count, avg_balance, profit_estimate     |
| 2 | Revenue by branch — map       | Bubble map          | `SUM(revenue_usd)` per branch, sized by amount                |
| 3 | Top 10 branches               | Horizontal bar      | rank by revenue_usd                                           |
| 4 | Bottom 10 branches            | Horizontal bar      | rank by revenue_usd (highlights at-risk)                      |
| 5 | Branch cohort by region       | Box plot            | distribution of revenue per branch within each region          |
| 6 | New-account velocity          | Line                | `SUM(new_account_count)` by month, per branch                 |
| 7 | Loan default rate by branch   | Diverging bar       | `default_rate_pct` from `fct_loan_portfolio`                  |

### Interactions
- Row click on tile 1 → opens "Branch detail" page (single-branch focus, all tiles re-filtered).
- Region filter at top → cascades to every tile.

### Acceptance test
Tile 1 row counts must equal `SELECT COUNT(DISTINCT branch_id) FROM FCT_BRANCH_PERFORMANCE`.

---

## Cross-cutting design principles

1. **One mart per dashboard.** Every tile must trace to a single fact/view (no ad-hoc joins in the BI tool). If a tile needs a new join, the right answer is a new mart, not a new BI query.
2. **No raw PII.** Customer names render via the masking policy; account numbers never appear.
3. **SLO-driven refreshes.** Each dashboard declares a refresh cadence that matches the upstream mart's freshness SLA; tiles never claim fresher data than the warehouse can deliver.
4. **Drill-down is a privilege, not a default.** Aggregated tiles are visible to all viewers; row-level drill requires elevated role and is logged in `VW_ACCESS_AUDIT`.
5. **Every tile has a definition popover.** Click the (i) icon → see SQL behind the measure. Lineage from BI to mart to source is one click.

## Out of scope (deliberate)

- **Real-time dashboard updates** (e.g. WebSocket-based live tiles). The 5-min Streams/Tasks cadence is the freshness floor; sub-minute updates would require Snowflake Streaming + a different mart strategy.
- **Mobile layouts.** Specs assume desktop / large screen; mobile is a separate effort.
- **Embedded analytics in customer-facing apps.** Compliance + RBAC implications take a separate review.
