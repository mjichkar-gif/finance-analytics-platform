{{
    config(
        materialized = 'ephemeral',
        tags         = ['intermediate','transactions']
    )
}}

/*
  int_transactions_enriched
  --------------------------
  Joins cleansed transactions with the latest customer + account + branch
  context and converts the amount into reporting currency (USD) using the
  monthly FX seed.

  Output grain: 1 row per transaction.

  Downstream consumers:
    * fct_transactions
    * fct_fraud_indicators
    * fct_revenue_monthly
*/

with txn as (
    select * from {{ ref('stg_transactions') }}
),

acct as (
    select * from {{ ref('stg_accounts') }}
),

cust as (
    select * from {{ ref('stg_customers') }}
),

brnch as (
    select * from {{ ref('stg_branches') }}
),

fx as (
    select
          upper(currency)                    as currency
        , date_trunc('month', effective_month)::date  as fx_month
        , rate_to_usd
    from {{ ref('exchange_rates') }}
),

fx_per_txn as (
    select
          t.transaction_sk
        , coalesce(f.rate_to_usd, 1.0)       as rate_to_usd
    from txn t
    left join fx f
      on  f.currency = t.currency
      and f.fx_month = date_trunc('month', t.transaction_date)::date
),

enriched as (
    select
          t.transaction_sk
        , t.transaction_id
        , t.transaction_timestamp
        , t.transaction_date
        , t.transaction_type
        , t.transaction_status
        , t.merchant_category
        , t.amount                                                   as amount_local
        , t.currency
        , round(t.amount * fx.rate_to_usd, 2)                        as amount_usd
        , a.account_sk
        , a.account_id
        , a.account_type
        , a.account_status
        , c.customer_sk
        , c.customer_id
        , c.customer_segment
        , c.risk_category                                            as customer_risk_category
        , b.branch_sk
        , b.branch_id
        , b.branch_name
        , b.region                                                   as branch_region
        , b.state                                                    as branch_state
        , c.region                                                   as customer_region
        -- Fraud heuristics expressed as flags
        , case when t.transaction_status = 'BLOCKED'                 then 1 else 0 end as is_blocked_flag
        , case when t.transaction_status in ('FAILED','REVERSED','BLOCKED') then 1 else 0 end as is_failed_flag
        , case
              when round(t.amount * fx.rate_to_usd, 2) >= {{ var('fraud_round_high_value_usd') }}
                   and mod(round(t.amount * fx.rate_to_usd, 0), 1000) = 0
              then 1
              else 0
          end                                                        as is_round_high_value_flag
        , case
              when round(t.amount * fx.rate_to_usd, 2) >= {{ var('fraud_high_value_usd') }}
              then 1
              else 0
          end                                                        as is_high_value_flag
    from   txn  t
    join   fx_per_txn fx on fx.transaction_sk = t.transaction_sk
    left join acct  a on a.account_id  = t.account_id
    left join cust  c on c.customer_id = a.customer_id
    left join brnch b on b.branch_id   = a.branch_id
)

select * from enriched
