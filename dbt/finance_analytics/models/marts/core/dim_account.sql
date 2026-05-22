{{ config(materialized='table', tags=['mart','core','dim']) }}

select
      a.account_sk
    , a.account_id
    , a.customer_id
    , a.account_type
    , a.account_status
    , a.branch_id
    , b.branch_name
    , b.region          as branch_region
    , a.open_date
    , datediff('day', a.open_date, current_date()) as account_age_days
from {{ ref('stg_accounts') }} a
left join {{ ref('stg_branches') }} b
       on b.branch_id = a.branch_id
