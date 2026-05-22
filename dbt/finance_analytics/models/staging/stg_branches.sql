{{ config(materialized='view', tags=['staging','branches']) }}

select
      {{ dbt_utils.generate_surrogate_key(['branch_id']) }}             as branch_sk
    , upper(trim(branch_id))                                            as branch_id
    , initcap(trim(branch_name))                                        as branch_name
    , initcap(trim(city))                                               as city
    , upper(trim(state))                                                as state
    , initcap(trim(region))                                             as region
    , _fivetran_synced                                                  as loaded_at
from {{ source('fin_raw', 'raw_branches') }}
where _fivetran_deleted = false
  and branch_id is not null
