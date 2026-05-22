# Fivetran Setup Runbook

> **Phase 3 deliverable.** Step-by-step configuration of the ingestion layer
> from Google Sheets into Snowflake `FIN_RAW`.

---

## 1. Architecture refresher

```
[Ops Google Sheets] --> [Fivetran Google Sheets connector] --> [Snowflake destination] --> FIN_ANALYTICS.FIN_RAW.RAW_*
```

Each operational entity (customers, accounts, transactions, loans, branches,
calendar) is one Sheet (or one tab in a master Sheet). One Fivetran connector
per Sheet keeps blast radius small and lets us pause individual feeds.

---

## 2. Prerequisites

| Item                     | Owner            | Notes |
|--------------------------|------------------|-------|
| Snowflake setup complete | Data Eng         | Phase 2 SQL applied; `FIVETRAN_LOADER` role exists. |
| Snowflake key-pair auth  | Data Eng         | Generate RSA key pair; assign public key to `FIVETRAN_USER`. |
| Google Sheets share      | Finance Ops      | Each Sheet shared (Viewer) with the Fivetran service account. |
| Fivetran tenant          | Platform         | Free trial is enough for POC. |

---

## 3. Configure the Snowflake destination

In Fivetran → **Destinations** → **Add Destination** → **Snowflake**:

| Field                  | Value                                                    |
|------------------------|----------------------------------------------------------|
| Host                   | `<your-account>.snowflakecomputing.com`                  |
| User                   | `FIVETRAN_USER`                                          |
| Authentication         | Key Pair                                                 |
| Private key            | paste contents of `rsa_key.p8`                           |
| Role                   | `FIVETRAN_LOADER`                                        |
| Warehouse              | `WH_FIN_INGEST`                                          |
| Database               | `FIN_ANALYTICS`                                          |
| Default schema prefix  | _leave blank_ — we'll specify the target schema per connector |

Click **Save & Test**. Fivetran runs ~6 validation checks; all must pass.

---

## 4. Configure the Google Sheets source

For each of the six sheets create a connector:

| Connector name          | Sheet name        | Target schema | Target table         |
|-------------------------|-------------------|---------------|----------------------|
| `gsheet_fin_customers`  | `customers`       | `FIN_RAW`     | `RAW_CUSTOMERS`      |
| `gsheet_fin_accounts`   | `accounts`        | `FIN_RAW`     | `RAW_ACCOUNTS`       |
| `gsheet_fin_txn`        | `transactions`    | `FIN_RAW`     | `RAW_TRANSACTIONS`   |
| `gsheet_fin_loans`      | `loans`           | `FIN_RAW`     | `RAW_LOANS`          |
| `gsheet_fin_branches`   | `branches`        | `FIN_RAW`     | `RAW_BRANCHES`       |
| `gsheet_fin_calendar`   | `calendar_dim`    | `FIN_RAW`     | `RAW_CALENDAR_DIM`   |

Steps for each connector:

1. **Connectors** → **Add Connector** → **Google Sheets**.
2. **Connection name**: use the value from the first column above (lowercase, snake_case — this is also the Fivetran group name).
3. **Authenticate** with the service account that has Viewer access.
4. **Sheet URL**: paste the link to that specific Sheet.
5. **Named range**: select the entire data range, e.g. `customers!A:F`. Named ranges are strongly preferred over raw ranges — they expand when ops add rows and protect against off-by-one column drift.
6. **Destination schema**: `FIN_RAW`.
7. **Destination table**: from the table above. Prefix with `RAW_` so the medallion convention is preserved in the warehouse.
8. **Sync mode**:
   - For static reference data (`branches`, `calendar_dim`): **Re-import on every sync**.
   - For mutable data (`customers`, `accounts`, `loans`): **Append + delete** with `_FIVETRAN_DELETED` soft-delete column.
   - For high-volume (`transactions`): same as mutable; Fivetran handles upserts on the natural key.

---

## 5. Sync schedule

| Connector              | Interval | Justification |
|------------------------|----------|---------------|
| `gsheet_fin_txn`       | 15 min   | Highest business value (fraud, ops reconciliation). |
| `gsheet_fin_customers` | 1 hour   | Slow-changing master data. |
| `gsheet_fin_accounts`  | 1 hour   | Slow-changing. |
| `gsheet_fin_loans`     | 1 hour   | Daily disbursement batch — hourly is conservative. |
| `gsheet_fin_branches`  | 24 hours | Stable reference. |
| `gsheet_fin_calendar`  | 24 hours | Stable reference. |

> Fivetran consumes MAR (monthly active rows) — keep static dims on slower intervals to control cost.

---

## 6. Naming conventions enforced

| Layer                 | Pattern                          | Example                  |
|-----------------------|----------------------------------|--------------------------|
| Fivetran connector    | `gsheet_fin_<entity>`            | `gsheet_fin_txn`         |
| Snowflake schema      | `FIN_<layer>`                    | `FIN_RAW`                |
| Snowflake table       | `RAW_<entity>` (UPPER)           | `RAW_TRANSACTIONS`       |
| Column casing         | UPPER_SNAKE_CASE (Snowflake norm)| `TRANSACTION_TIMESTAMP`  |
| Fivetran sys columns  | `_FIVETRAN_SYNCED`, `_FIVETRAN_DELETED` | retained as-is    |

---

## 7. Validation checklist (post-first-sync)

```sql
USE ROLE FIN_ADMIN;
USE DATABASE FIN_ANALYTICS;

-- 1. All expected tables exist
SHOW TABLES IN SCHEMA FIN_RAW;

-- 2. Row counts are sane
SELECT 'RAW_CUSTOMERS', COUNT(*) FROM FIN_RAW.RAW_CUSTOMERS
UNION ALL SELECT 'RAW_TRANSACTIONS', COUNT(*) FROM FIN_RAW.RAW_TRANSACTIONS;

-- 3. Fivetran metadata columns present
SELECT MAX(_FIVETRAN_SYNCED) FROM FIN_RAW.RAW_TRANSACTIONS;

-- 4. No unexpected NULLs in business keys (DQ smoke test)
SELECT COUNT(*) FROM FIN_RAW.RAW_TRANSACTIONS WHERE TRANSACTION_ID IS NULL;
```

---

## 8. Common issues and fixes

| Symptom                                                  | Likely cause                                  | Resolution |
|----------------------------------------------------------|-----------------------------------------------|------------|
| `Permission denied` on Snowflake destination test        | `FIVETRAN_LOADER` missing CREATE TABLE on `FIN_RAW` | Re-run `01_account_setup.sql` grant block. |
| Connector stuck in **schema change pending** status      | Ops team added a column to the Sheet          | Approve the column in Fivetran → Schema; add it to the matching `sources.yml`. |
| Numbers landing as VARCHAR                               | Sheet cell formatted as Plain Text            | Fix the Sheet column format, then **Resync historical data**. |
| Date column lands as VARCHAR `'45123'`                    | Sheets serial-date number                     | Format the source column as Date; in `stg_*` model use `TRY_TO_DATE`. |
| `_FIVETRAN_DELETED` rows never appear                    | Sync mode set to "Append only"                | Switch the connector to **Append + delete**. |
| MAR usage spikes                                         | High-frequency interval on a slow-changing sheet | Move sheet to 24h cadence. |

---

## 9. Cost & monitoring

- Tag each connector with `env=poc` / `env=prod` (Fivetran → Settings → Tags) so finance can split the bill.
- Pipe Fivetran logs into the `FIN_AUDIT` schema via the **Fivetran Logs** connector — gives us a queryable history of every sync.
- Alert via Slack on:
  - Connector status = `BROKEN`
  - Sync duration > 2× the 30-day rolling average
  - Row drift > 50% vs previous sync (probably a Sheet was wiped)
