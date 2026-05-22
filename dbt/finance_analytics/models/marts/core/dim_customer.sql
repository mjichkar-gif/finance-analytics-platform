{{ config(materialized='table', tags=['mart','core','dim']) }}

/*
  dim_customer
  -------------
  Currently-effective customer record. Joins through the snapshot to
  expose dbt_valid_from / dbt_valid_to so downstream facts can do
  point-in-time joins on customer_sk if needed.

  For BI consumption use this table (current view). For audit/vintage
  analysis use the snapshot directly: ref('snap_customers').
*/

with current_snap as (
    select *
    from {{ ref('snap_customers') }}
    where dbt_valid_to is null   -- currently effective record
),

stg as (
    select * from {{ ref('stg_customers') }}
)

select
      coalesce(s.customer_sk, c.customer_sk)                          as customer_sk
    , coalesce(s.customer_id, c.customer_id)                          as customer_id
    , coalesce(c.customer_name,     s.customer_name)                  as customer_name
    , coalesce(c.customer_segment,  s.customer_segment)               as customer_segment
    , coalesce(c.risk_category,     s.risk_category)                  as risk_category
    , coalesce(c.region,            s.region)                         as region
    , coalesce(c.onboarding_date,   s.onboarding_date)                as onboarding_date
    , c.dbt_valid_from                                                as scd_valid_from
    , c.dbt_valid_to                                                  as scd_valid_to
from stg s
left join current_snap c
  on c.customer_id = s.customer_id
