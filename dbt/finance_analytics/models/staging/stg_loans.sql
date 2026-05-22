{{ config(materialized='view', tags=['staging','loans']) }}

with source as (
    select *
    from {{ source('fin_raw', 'raw_loans') }}
    where _fivetran_deleted = false
      and loan_id is not null
),

cleansed as (
    select
          upper(trim(loan_id))                                          as loan_id
        , upper(trim(customer_id))                                      as customer_id
        , upper(trim(loan_type))                                        as loan_type
        , loan_amount
        , interest_rate
        , emi_amount
        , upper(trim(loan_status))                                      as loan_status
        , disbursement_date
        , _fivetran_synced                                              as loaded_at
        , row_number() over (
              partition by upper(trim(loan_id))
              order by     _fivetran_synced desc
          ) as rn
    from source
)

select
      {{ dbt_utils.generate_surrogate_key(['loan_id']) }}               as loan_sk
    , loan_id
    , customer_id
    , loan_type
    , loan_amount
    , interest_rate
    , emi_amount
    , loan_status
    , case when loan_status in ('DEFAULTED','WRITTEN_OFF') then 1 else 0 end  as is_default_flag
    , case when loan_status = 'DELINQUENT'                  then 1 else 0 end  as is_delinquent_flag
    , case when loan_status in ('ACTIVE','DELINQUENT')      then 1 else 0 end  as is_active_flag
    , disbursement_date
    , loaded_at
from cleansed
where rn = 1
