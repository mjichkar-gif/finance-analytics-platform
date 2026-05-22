# Dimensional Model — Star Schema Design

> **Phase 5 deliverable.** Defines the analytics-ready model, the grain of each
> fact table, the relationships, and the surrogate-key strategy.

## 1. Schema overview (star)

```
                        +-----------------+
                        |   DIM_DATE      |
                        |  (date_sk)      |
                        +--------+--------+
                                 |
       +-----------------+       |        +------------------+
       |  DIM_CUSTOMER   |       |        |   DIM_BRANCH     |
       |  (customer_sk,  |       |        |  (branch_sk)     |
       |   SCD-2)        |       |        +---------+--------+
       +--------+--------+       |                  |
                |                |                  |
                |   +------------+-------------+    |
                |   |       FCT_TRANSACTIONS   |    |
                +-->|  grain: 1 row / txn      |<---+
                    |  measures: amount_usd,   |
                    |    is_fraud_flag,        |
                    |    is_failed_flag        |
                    +------------+-------------+
                                 ^
                                 |
                        +--------+--------+
                        |  DIM_ACCOUNT    |
                        |  (account_sk,   |
                        |   SCD-2)        |
                        +-----------------+

       +-----------------+      +----------------------------+
       |  DIM_CUSTOMER   |      |    FCT_LOANS               |
       |                 +----->| grain: 1 row / loan        |
       +-----------------+      |  measures: principal,      |
                                |    outstanding_bal,        |
                                |    interest_accrued,       |
                                |    is_default_flag         |
                                +-------------+--------------+
                                              |
                                +-------------+--------------+
                                |  FCT_LOAN_BALANCES_DAILY   |
                                |  grain: 1 row / loan / day |
                                +----------------------------+
```

## 2. Grain declarations

| Fact table                  | Grain                                         | Volume (target) |
|-----------------------------|-----------------------------------------------|-----------------|
| `fct_transactions`          | 1 row per posted transaction                  | ~5 M/day        |
| `fct_loans`                 | 1 row per active loan (current state)         | ~50 k snapshot  |
| `fct_loan_balances_daily`   | 1 row per active loan per day                 | ~50 k × 365     |

## 3. Dimensions

| Dim               | Type | Natural key   | Surrogate key  | Notes |
|-------------------|------|---------------|----------------|-------|
| `dim_date`        | 1    | `date_key`    | `date_sk`      | Conformed across all facts. |
| `dim_customer`    | 2    | `customer_id` | `customer_sk`  | Tracks segment/risk changes. |
| `dim_account`     | 2    | `account_id`  | `account_sk`   | Tracks status changes. |
| `dim_branch`      | 1    | `branch_id`   | `branch_sk`    | Stable. |
| `dim_loan_type`   | 1    | `loan_type`   | `loan_type_sk` | Derived. |
| `dim_merchant_category` | 1 | `merchant_category` | `mcat_sk`  | Derived. |

## 4. Surrogate key strategy

All surrogate keys are produced via:

```jinja
{{ dbt_utils.generate_surrogate_key(['<natural_key_cols>']) }}
```

This yields a deterministic MD5. Benefits:

- Identical SK across `dev`, `staging`, `prod` for the same row.
- No reliance on Snowflake sequences (which drift across rebuilds).
- Safe to JOIN incremental fact runs against full-refreshed dims.

For SCD-2 dims, the SK includes the effective-from timestamp:

```jinja
{{ dbt_utils.generate_surrogate_key(['customer_id', 'dbt_valid_from']) }}
```

## 5. Conformed measures

| Measure              | Definition                                      | Lives in           |
|----------------------|-------------------------------------------------|--------------------|
| `amount_usd`         | `amount * fx_rate_to_usd_at_txn_date`           | `fct_transactions` |
| `is_fraud_flag`      | 1 if status='BLOCKED' OR amount_usd > 50k OR rapid-fire window match | `fct_transactions` |
| `is_failed_flag`     | 1 if status IN ('FAILED','REVERSED','BLOCKED')  | `fct_transactions` |
| `outstanding_balance`| principal × remaining factor                    | `fct_loan_balances_daily` |
| `is_default_flag`    | 1 if loan_status IN ('DEFAULTED','WRITTEN_OFF') | `fct_loans`        |

## 6. Slowly-changing rules

- `dim_customer.customer_segment` — Type 2
- `dim_customer.risk_category`    — Type 2
- `dim_customer.customer_name`    — Type 1 (correct typos in place)
- `dim_account.account_status`    — Type 2
- All other attributes            — Type 1
