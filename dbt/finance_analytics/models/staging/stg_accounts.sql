{{ config(materialized='view', tags=['staging','accounts']) }}

with source as (
    select *
    from {{ source('fin_raw', 'raw_accounts') }}
    where _fivetran_deleted = false
      and account_id is not null
),

cleansed as (
    select
          upper(trim(account_id))                                       as account_id
        , upper(trim(customer_id))                                      as customer_id
        , upper(trim(account_type))                                     as account_type
        , upper(trim(branch_id))                                        as branch_id
        , coalesce(upper(trim(account_status)), 'UNKNOWN')              as account_status
        , open_date
        , _fivetran_synced                                              as loaded_at
        , row_number() over (
              partition by upper(trim(account_id))
              order by     _fivetran_synced desc
          ) as rn
    from source
)

select
      {{ dbt_utils.generate_surrogate_key(['account_id']) }}            as account_sk
    , account_id
    , customer_id
    , account_type
    , branch_id
    , account_status
    , open_date
    , loaded_at
from cleansed
where rn = 1
