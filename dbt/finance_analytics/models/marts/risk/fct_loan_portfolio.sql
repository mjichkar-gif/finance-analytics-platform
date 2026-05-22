{{ config(materialized='table', tags=['mart','risk','portfolio']) }}

/*
  fct_loan_portfolio
  ------------------
  Portfolio-level risk and exposure mart at loan_type × region grain.
  Answers BQ-3.1, 3.2, 3.3.
*/

with l as (
    select * from {{ ref('fct_loans') }}
)

select
      loan_type
    , customer_region
    , customer_segment
    , customer_risk_category
    , count(*)                                              as loan_count
    , sum(loan_amount)                                      as total_principal_usd
    , sum(outstanding_balance_est)                          as total_outstanding_usd
    , sum(case when is_default_flag    = 1 then 1 else 0 end) as defaulted_count
    , sum(case when is_delinquent_flag = 1 then 1 else 0 end) as delinquent_count
    , sum(case when is_active_flag     = 1 then 1 else 0 end) as active_count
    , round(
          sum(case when is_default_flag = 1 then loan_amount else 0 end)
          / nullif(sum(loan_amount), 0) * 100, 2)            as default_rate_pct
    , round(avg(interest_rate), 2)                           as avg_interest_rate
    , round(avg(loan_amount), 2)                             as avg_loan_principal
from l
group by 1,2,3,4
