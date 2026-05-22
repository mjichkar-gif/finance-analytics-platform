{# ============================================================================
   log_dbt_run_results.sql
   ----------------------------------------------------------------------------
   on-run-end hook that appends the result of every model/test/snapshot
   execution to FIN_ANALYTICS.FIN_AUDIT.DBT_RUN_RESULTS for later DQ
   reporting and SLA tracking.
   ============================================================================ #}

{% macro log_dbt_run_results() -%}

    {% if execute and results %}

        {% set audit_table = 'FIN_ANALYTICS.FIN_AUDIT.DBT_RUN_RESULTS' %}

        {# Ensure the audit table exists #}
        {% set create_sql -%}
            CREATE TABLE IF NOT EXISTS {{ audit_table }} (
                  INVOCATION_ID    VARCHAR
                , RUN_STARTED_AT   TIMESTAMP_NTZ
                , RUN_COMPLETED_AT TIMESTAMP_NTZ
                , NODE_NAME        VARCHAR
                , NODE_TYPE        VARCHAR
                , STATUS           VARCHAR
                , EXECUTION_TIME_S NUMBER(18,4)
                , MESSAGE          VARCHAR
                , TARGET_NAME      VARCHAR
                , INSERTED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
            );
        {%- endset %}
        {% do run_query(create_sql) %}

        {% set rows = [] %}
        {% for r in results %}
            {% set message = (r.message or '') | replace("'", "''") %}
            {% set row -%}
                ('{{ invocation_id }}',
                 '{{ run_started_at }}',
                 CURRENT_TIMESTAMP(),
                 '{{ r.node.name }}',
                 '{{ r.node.resource_type }}',
                 '{{ r.status }}',
                 {{ r.execution_time }},
                 '{{ message }}',
                 '{{ target.name }}')
            {%- endset %}
            {% do rows.append(row) %}
        {% endfor %}

        {% if rows | length > 0 %}
            {% set insert_sql -%}
                INSERT INTO {{ audit_table }}
                    (INVOCATION_ID, RUN_STARTED_AT, RUN_COMPLETED_AT,
                     NODE_NAME, NODE_TYPE, STATUS, EXECUTION_TIME_S,
                     MESSAGE, TARGET_NAME)
                VALUES {{ rows | join(',\n        ') }};
            {%- endset %}
            {% do run_query(insert_sql) %}
            {% do log("Logged " ~ rows | length ~ " dbt results to " ~ audit_table, info=True) %}
        {% endif %}

    {% endif %}

{%- endmacro %}
