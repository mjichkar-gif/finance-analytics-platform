{{ config(materialized='view', tags=['staging','calendar']) }}

select
      {{ dbt_utils.generate_surrogate_key(['date_key']) }}              as date_sk
    , date_key
    , month
    , quarter
    , year
    , fiscal_period
    , dayofweek(date_key)                                               as day_of_week
    , dayname(date_key)                                                 as day_name
    , monthname(date_key)                                               as month_name
    , case when dayofweek(date_key) in (0, 6) then 1 else 0 end         as is_weekend
    , last_day(date_key, 'month')                                       as month_end_date
    , last_day(date_key, 'quarter')                                     as quarter_end_date
from {{ source('fin_raw', 'raw_calendar_dim') }}
where _fivetran_deleted = false
  and date_key is not null
