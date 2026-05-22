{{ config(materialized='table', tags=['mart','finance','regional']) }}

/*
  fct_branch_performance
  -----------------------
  Branch × month performance. Answers BQ-5.
*/

with txn as (
    select * from {{ ref('fct_transactions') }}
    where transaction_status = 'COMPLETED'
),

branch_dim as (
    select * from {{ ref('dim_branch') }}
)

select
      date_trunc('month', t.transaction_date)::date            as performance_month
    , b.branch_id
    , b.branch_name
    , b.city
    , b.state
    , b.region
    , count(distinct t.account_id)                             as active_accounts
    , count(distinct t.customer_id)                            as active_customers
    , count(*)                                                 as transaction_count
    , sum(t.amount_usd)                                        as total_volume_usd
    , sum(case when t.transaction_type in ('CREDIT','FEE','INTEREST')
                then t.amount_usd else 0 end)                  as revenue_usd
    , sum(t.is_failed_flag)                                    as failed_count
    , sum(t.is_high_value_flag)                                as high_value_count
    , round(sum(t.is_failed_flag) * 100.0 / nullif(count(*),0), 2) as failed_pct
from txn t
join branch_dim b on b.branch_id = t.branch_id
group by 1,2,3,4,5,6
