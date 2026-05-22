{{ config(materialized='table', tags=['mart','core','dim']) }}

select
      date_sk
    , date_key
    , year
    , quarter
    , month
    , month_name
    , day_of_week
    , day_name
    , is_weekend
    , fiscal_period
    , month_end_date
    , quarter_end_date
from {{ ref('stg_calendar_dim') }}
