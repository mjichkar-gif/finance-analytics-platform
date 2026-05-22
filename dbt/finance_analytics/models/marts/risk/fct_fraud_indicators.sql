{{ config(materialized='table', tags=['mart','risk','fraud']) }}

/*
  fct_fraud_indicators
  --------------------
  Transaction-grain mart limited to suspicious activity. Output is
  consumed both by the analyst-facing fraud dashboard and the
  Snowflake task that paginates results into FIN_AUDIT.SUSPICIOUS_TRANSACTIONS
  for the ops queue.

  Rules:
    1. Blocked status
    2. Amount >= var('fraud_high_value_usd')
    3. Round-number ≥ var('fraud_round_high_value_usd')
    4. Rapid-fire — 3+ transactions on the same account within 60 min
*/

with txn as (
    select * from {{ ref('fct_transactions') }}
),

rapid_fire as (
    select
          transaction_sk
        , account_id
        , count(*) over (
              partition by account_id
              order by transaction_timestamp
              range between interval '60 minutes' preceding and current row
          ) as txn_count_60min
    from txn
),

flagged as (
    select
          t.transaction_sk
        , t.transaction_id
        , t.transaction_timestamp
        , t.transaction_date
        , t.account_id
        , t.customer_id
        , t.customer_segment
        , t.customer_risk_category
        , t.branch_region
        , t.amount_usd
        , t.currency
        , t.transaction_status
        , t.merchant_category
        , t.is_blocked_flag
        , t.is_high_value_flag
        , t.is_round_high_value_flag
        , case when r.txn_count_60min >= 3 then 1 else 0 end       as is_rapid_fire_flag
        , array_construct_compact(
              case when t.is_blocked_flag           = 1 then 'STATUS_BLOCKED'           end
            , case when t.is_round_high_value_flag  = 1 then 'ROUND_NUMBER_HIGH_VALUE'  end
            , case when t.is_high_value_flag        = 1 then 'HIGH_VALUE'               end
            , case when r.txn_count_60min >= 3          then 'RAPID_FIRE'               end
          )                                                        as flag_reasons
    from txn t
    join rapid_fire r on r.transaction_sk = t.transaction_sk
)

select
      *
    , array_size(flag_reasons)                                     as flag_count
from flagged
where array_size(flag_reasons) > 0
