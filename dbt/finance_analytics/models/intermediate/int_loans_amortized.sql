{{ config(materialized='ephemeral', tags=['intermediate','loans']) }}

/*
  int_loans_amortized
  --------------------
  Adds simple loan analytics columns:
    * estimated_total_repayment   = emi_amount * months_since_disbursement (capped)
    * outstanding_balance_est     = loan_amount - estimated_total_repayment (floored at 0)
    * months_since_disbursement
    * loan_tenure_months_estimate (derived from loan_amount / emi)

  Note: this is an *estimate* model — a real platform would join to a
  servicing ledger. For analytics-fitness it captures the right shape.
*/

with loans as (
    select * from {{ ref('stg_loans') }}
),

amortized as (
    select
          l.loan_sk
        , l.loan_id
        , l.customer_id
        , l.loan_type
        , l.loan_amount
        , l.interest_rate
        , l.emi_amount
        , l.loan_status
        , l.is_default_flag
        , l.is_delinquent_flag
        , l.is_active_flag
        , l.disbursement_date
        , datediff('month', l.disbursement_date, current_date())     as months_since_disbursement
        , greatest(round(l.loan_amount / nullif(l.emi_amount, 0)), 0) as loan_tenure_months_estimate
        , least(
              datediff('month', l.disbursement_date, current_date()),
              greatest(round(l.loan_amount / nullif(l.emi_amount, 0)), 0)
          )                                                          as effective_months_paid
    from loans l
),

balance as (
    select
          *
        , round(emi_amount * effective_months_paid, 2)               as estimated_total_repaid
        , greatest(
              round(loan_amount - (emi_amount * effective_months_paid), 2),
              0
          )                                                          as outstanding_balance_est
    from amortized
)

select * from balance
