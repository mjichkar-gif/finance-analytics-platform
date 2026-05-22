{{
    config(
        materialized      = 'incremental',
        unique_key        = 'transaction_sk',
        incremental_strategy = 'merge',
        on_schema_change  = 'sync_all_columns',
        cluster_by        = ['transaction_date'],
        tags              = ['mart','finance','fact','incremental']
    )
}}

/*
  fct_transactions
  ----------------
  Grain: 1 row per posted transaction.
  Incremental on transaction_timestamp with a configurable late-arriving
  overlap window (default 24h) so a Sheets backfill at 02:00 still lands.

  Note: ephemeral intermediate model means the JOIN logic compiles inline
  here — no extra table to materialize.
*/

with src as (
    select * from {{ ref('int_transactions_enriched') }}

    {% if is_incremental() %}
    where transaction_timestamp >= (
        select coalesce(
                  max(transaction_timestamp)
                       - interval '{{ var("txn_late_arrival_overlap_hours") }} hour',
                  '1900-01-01'::timestamp_ntz
              )
        from {{ this }}
    )
    {% endif %}
)

select
      transaction_sk
    , transaction_id
    , transaction_timestamp
    , transaction_date
    , transaction_type
    , transaction_status
    , merchant_category
    , amount_local
    , currency
    , amount_usd
    , account_sk
    , account_id
    , customer_sk
    , customer_id
    , customer_segment
    , customer_risk_category
    , branch_sk
    , branch_id
    , branch_region
    , branch_state
    , is_failed_flag
    , is_blocked_flag
    , is_high_value_flag
    , is_round_high_value_flag
    , current_timestamp() as dbt_loaded_at
from src
