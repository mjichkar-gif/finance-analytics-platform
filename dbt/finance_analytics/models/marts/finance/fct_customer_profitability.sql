{{ config(materialized='table', tags=['mart','finance','customer']) }}

/*
  fct_customer_profitability
  --------------------------
  Customer-grain profitability metrics (BQ-2).

  Profitability proxy:
      revenue        = fee/interest/credit inflows (USD)
      cost_of_funds  = sum of outstanding loan balance * (interest_rate / 100) / 12
                       summed for the customer's active months
      profit_estimate= revenue - cost_of_funds_proxy

  This is a *proxy* — a real implementation would include:
      * branch ops cost allocation
      * fraud loss
      * loan loss provisions
*/

with cust as (
    select * from {{ ref('dim_customer') }}
),

txn_agg as (
    select
          customer_id
        , sum(case when transaction_type in ('CREDIT','FEE','INTEREST')
                        and transaction_status = 'COMPLETED'
                  then amount_usd else 0 end)                          as total_revenue_usd
        , sum(case when transaction_type = 'REFUND'
                        and transaction_status = 'COMPLETED'
                  then amount_usd else 0 end)                          as total_refund_usd
        , count(*)                                                     as total_txn_count
        , sum(is_failed_flag)                                          as failed_txn_count
        , sum(is_high_value_flag)                                      as high_value_txn_count
        , min(transaction_date)                                        as first_txn_date
        , max(transaction_date)                                        as last_txn_date
    from {{ ref('fct_transactions') }}
    group by 1
),

loan_agg as (
    select
          customer_id
        , count(*)                                                     as loan_count
        , sum(loan_amount)                                             as total_loan_principal
        , sum(outstanding_balance_est)                                 as total_outstanding_usd
        , sum(case when is_default_flag = 1 then 1 else 0 end)         as defaulted_loan_count
        , avg(interest_rate)                                           as avg_interest_rate
    from {{ ref('fct_loans') }}
    group by 1
),

joined as (
    select
          c.customer_sk
        , c.customer_id
        , c.customer_name
        , c.customer_segment
        , c.risk_category
        , c.region
        , c.onboarding_date
        , datediff('day', c.onboarding_date, current_date())           as tenure_days
        , coalesce(t.total_revenue_usd, 0)                             as total_revenue_usd
        , coalesce(t.total_refund_usd,  0)                             as total_refund_usd
        , coalesce(t.total_revenue_usd, 0) - coalesce(t.total_refund_usd, 0) as net_revenue_usd
        , coalesce(t.total_txn_count, 0)                               as total_txn_count
        , coalesce(t.failed_txn_count, 0)                              as failed_txn_count
        , coalesce(t.high_value_txn_count, 0)                          as high_value_txn_count
        , t.first_txn_date
        , t.last_txn_date
        , coalesce(l.loan_count, 0)                                    as loan_count
        , coalesce(l.total_loan_principal, 0)                          as total_loan_principal
        , coalesce(l.total_outstanding_usd, 0)                         as total_outstanding_usd
        , coalesce(l.defaulted_loan_count, 0)                          as defaulted_loan_count
        , coalesce(l.avg_interest_rate, 0)                             as avg_loan_interest_rate
    from cust c
    left join txn_agg  t on t.customer_id = c.customer_id
    left join loan_agg l on l.customer_id = c.customer_id
),

with_profit as (
    select
          *
        -- monthly carrying cost (interest only) proxy across tenure
        , round(total_outstanding_usd * (avg_loan_interest_rate/100.0) / 12.0
                * greatest(tenure_days / 30.0, 1), 2)                  as cost_of_funds_proxy_usd
        , round(
              net_revenue_usd -
              (total_outstanding_usd * (avg_loan_interest_rate/100.0) / 12.0
                * greatest(tenure_days / 30.0, 1))
          , 2)                                                         as profit_estimate_usd
        , case
              when risk_category = 'HIGH'   and net_revenue_usd > 10000 then 'HIGH_RISK_HIGH_VALUE'
              when risk_category = 'HIGH'                               then 'HIGH_RISK_LOW_VALUE'
              when risk_category = 'LOW'    and net_revenue_usd > 10000 then 'LOW_RISK_HIGH_VALUE'
              when risk_category = 'LOW'                                then 'LOW_RISK_LOW_VALUE'
              else 'MEDIUM_RISK'
          end                                                          as risk_value_segment
    from joined
)

select * from with_profit
