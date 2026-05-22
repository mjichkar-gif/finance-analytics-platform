{{ config(materialized='table', tags=['mart','finance','kpi']) }}

/*
  fct_quarterly_kpis
  ------------------
  Executive-level quarterly KPI snapshot with QoQ growth %.
  Answers BQ-6 (Financial KPIs).
*/

with monthly as (
    select * from {{ ref('fct_revenue_monthly') }}
),

quarterly as (
    select
          date_trunc('quarter', revenue_month)::date              as revenue_quarter
        , branch_region
        , sum(net_revenue_usd)                                    as net_revenue_usd
        , sum(inflow_usd)                                         as gross_inflow_usd
        , sum(refund_usd)                                         as refund_usd
        , sum(inflow_txn_count)                                   as inflow_txn_count
        , avg(active_customers)                                   as avg_active_customers
    from monthly
    group by 1,2
),

with_growth as (
    select
          q.*
        , lag(net_revenue_usd) over (
              partition by branch_region
              order by revenue_quarter
          )                                                       as prev_quarter_revenue
        , round(
              (net_revenue_usd
               - lag(net_revenue_usd) over (partition by branch_region order by revenue_quarter))
              / nullif(lag(net_revenue_usd) over (partition by branch_region order by revenue_quarter), 0)
              * 100, 2)                                           as qoq_growth_pct
        , round(net_revenue_usd
                / sum(net_revenue_usd) over (partition by revenue_quarter)
                * 100, 2)                                         as region_revenue_contribution_pct
    from quarterly q
)

select * from with_growth
order by revenue_quarter, branch_region
