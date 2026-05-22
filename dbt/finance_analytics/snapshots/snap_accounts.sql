{% snapshot snap_accounts %}

{{
    config(
        target_schema = 'snapshots',
        unique_key    = 'account_id',
        strategy      = 'check',
        check_cols    = ['account_status','branch_id','account_type'],
        invalidate_hard_deletes = true
    )
}}

select * from {{ ref('stg_accounts') }}

{% endsnapshot %}
