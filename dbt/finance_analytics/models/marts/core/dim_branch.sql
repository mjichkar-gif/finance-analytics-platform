{{ config(materialized='table', tags=['mart','core','dim']) }}

select
      branch_sk
    , branch_id
    , branch_name
    , city
    , state
    , region
from {{ ref('stg_branches') }}
