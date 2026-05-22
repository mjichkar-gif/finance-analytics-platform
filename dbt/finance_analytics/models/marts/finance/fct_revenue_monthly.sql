{{ config(materialized='table', tags=['mart','finance','revenue']) }}

/*
  fct_revenue_monthly
  --------------------
  Revenue mart at month × segment × region grain.
  Used for:
    * BQ-1.1  Monthly revenue trend
    * BQ-1.2  Revenue by region
    * BQ-1.3  Revenue by customer segment
    * BQ-6    Quarterly KPI roll-ups

  Definition of revenue (POC):
    * sum(amount_usd) where transaction_status = 'COMPLETED'
      AND transaction_type IN ('CREDIT','FEE','INTEREST')
    * negative-side transactions (DEBIT / TRANSFER outflow) are *outflows*
      and tracked separately. Net revenue = inflow - refund.
*/

with txn as (
    select * from {{ ref('fct_transactions') }}
    where transaction_status = 'COMPLETED'
),

monthly as (
    select
          date_trunc('month', transaction_date)::date as revenue_month
        , customer_segment
        , customer_risk_category
        , branch_region
        , sum(case when transaction_type in ('CREDIT','FEE','INTEREST')
                    then amount_usd else 0 end)                         as inflow_usd
        , sum(case when transaction_type = 'REFUND'
                    then amount_usd else 0 end)                         as refund_usd
        , count(case when transaction_type in ('CREDIT','FEE','INTEREST')
                    then 1 end)                                         as inflow_txn_count
        , count(distinct customer_id)                                   as active_customers
    from txn
    group by 1,2,3,4
)

select
      revenue_month
    , customer_segment
    , customer_risk_category
    , branch_region
    , inflow_usd
    , refund_usd
    , inflow_usd - refund_usd                                           as net_revenue_usd
    , inflow_txn_count
    , active_customers
    , round((inflow_usd - refund_usd) / nullif(active_customers, 0), 2) as avg_revenue_per_customer
from monthly
