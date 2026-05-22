{{
    config(
        materialized = 'view',
        tags         = ['staging','customers']
    )
}}

/*
  stg_customers
  -------------
  Cleansed customer master:
    * trims whitespace, normalizes name casing (Type-1 correction)
    * canonicalises enum values (segment, risk_category)
    * dedupes on customer_id keeping the latest Fivetran sync
    * exposes the SCD-2 surrogate key
*/

with source as (
    select *
    from {{ source('fin_raw', 'raw_customers') }}
    where _fivetran_deleted = false
      and customer_id is not null
),

cleansed as (
    select
          upper(trim(customer_id))                                  as customer_id
        , initcap(trim(customer_name))                              as customer_name
        , coalesce(upper(trim(customer_segment)), 'UNKNOWN')        as customer_segment
        , case upper(trim(risk_category))
              when 'LOW'    then 'LOW'
              when 'MEDIUM' then 'MEDIUM'
              when 'HIGH'   then 'HIGH'
              else 'UNKNOWN'
          end                                                       as risk_category
        , initcap(trim(region))                                     as region
        , onboarding_date
        , _fivetran_synced                                          as loaded_at
        , row_number() over (
              partition by upper(trim(customer_id))
              order by     _fivetran_synced desc
          )                                                         as rn
    from source
),

final as (
    select
          {{ dbt_utils.generate_surrogate_key(['customer_id']) }}   as customer_sk
        , customer_id
        , customer_name
        , customer_segment
        , risk_category
        , region
        , onboarding_date
        , loaded_at
    from cleansed
    where rn = 1
)

select * from final
