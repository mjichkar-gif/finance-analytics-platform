{% snapshot snap_customers %}

{{
    config(
        target_schema = 'snapshots',
        unique_key    = 'customer_id',
        strategy      = 'check',
        check_cols    = ['customer_segment','risk_category','region'],
        invalidate_hard_deletes = true
    )
}}

select
      customer_sk
    , customer_id
    , customer_name
    , customer_segment
    , risk_category
    , region
    , onboarding_date
    , loaded_at
from {{ ref('stg_customers') }}

{% endsnapshot %}
