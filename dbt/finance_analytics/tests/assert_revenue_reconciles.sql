/*
  Singular test: revenue reconciliation
  -------------------------------------
  Net revenue in fct_revenue_monthly must equal the sum of qualifying
  rows in fct_transactions to within a 1-cent rounding tolerance.

  Test passes when this query returns zero rows.
*/

with mart_total as (
    select sum(net_revenue_usd) as mart_net_revenue
    from {{ ref('fct_revenue_monthly') }}
),

fact_total as (
    select
        sum(case when transaction_type in ('CREDIT','FEE','INTEREST') then amount_usd else 0 end)
      - sum(case when transaction_type = 'REFUND' then amount_usd else 0 end) as fact_net_revenue
    from {{ ref('fct_transactions') }}
    where transaction_status = 'COMPLETED'
)

select
      mart_net_revenue
    , fact_net_revenue
    , abs(mart_net_revenue - fact_net_revenue) as variance
from mart_total, fact_total
where abs(mart_net_revenue - fact_net_revenue) > 0.01
