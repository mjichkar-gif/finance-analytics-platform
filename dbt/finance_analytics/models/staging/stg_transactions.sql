{{ config(materialized='view', tags=['staging','transactions']) }}

/*
  stg_transactions
  ----------------
  Cleansed transaction stream. Note: this is the VIEW used by dbt marts;
  near-real-time consumers should query FIN_STG.STG_TRANSACTIONS_INCR
  (populated by the Snowflake task on a 5-minute schedule).
*/

with source as (
    select *
    from {{ source('fin_raw', 'raw_transactions') }}
    where _fivetran_deleted = false
      and transaction_id is not null
      and amount         is not null
),

cleansed as (
    select
          upper(trim(transaction_id))                                   as transaction_id
        , upper(trim(account_id))                                       as account_id
        , upper(trim(transaction_type))                                 as transaction_type
        , amount                                                        as amount
        , upper(trim(currency))                                         as currency
        , upper(trim(merchant_category))                                as merchant_category
        , transaction_timestamp                                         as transaction_timestamp
        , cast(transaction_timestamp as date)                           as transaction_date
        , coalesce(upper(trim(transaction_status)), 'UNKNOWN')          as transaction_status
        , _fivetran_synced                                              as loaded_at
        , row_number() over (
              partition by upper(trim(transaction_id))
              order by     _fivetran_synced desc
          ) as rn
    from source
)

select
      {{ dbt_utils.generate_surrogate_key(['transaction_id']) }}        as transaction_sk
    , transaction_id
    , account_id
    , transaction_type
    , amount
    , currency
    , merchant_category
    , transaction_timestamp
    , transaction_date
    , transaction_status
    , loaded_at
from cleansed
where rn = 1
