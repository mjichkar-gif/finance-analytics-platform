{{ config(materialized='table', tags=['mart','risk','fact']) }}

with l as (
    select * from {{ ref('int_loans_amortized') }}
),
c as (
    select * from {{ ref('dim_customer') }}
)

select
      l.loan_sk
    , l.loan_id
    , l.loan_type
    , c.customer_sk
    , l.customer_id
    , c.customer_segment
    , c.risk_category                    as customer_risk_category
    , c.region                           as customer_region
    , l.loan_amount
    , l.interest_rate
    , l.emi_amount
    , l.loan_status
    , l.disbursement_date
    , l.months_since_disbursement
    , l.loan_tenure_months_estimate
    , l.effective_months_paid
    , l.estimated_total_repaid
    , l.outstanding_balance_est
    , l.is_default_flag
    , l.is_delinquent_flag
    , l.is_active_flag
    , current_timestamp() as dbt_loaded_at
from l
left join c on c.customer_id = l.customer_id
