{# ============================================================================
   set_query_tag.sql
   ----------------------------------------------------------------------------
   Tags every Snowflake query in this dbt invocation with:
       project, target, invocation_id, user
   so Snowflake's QUERY_HISTORY can be sliced by run for cost attribution.
   ============================================================================ #}

{% macro set_query_tag() -%}

    {% if target.type == 'snowflake' %}
        {% set tag = {
            "project":       project_name,
            "target":        target.name,
            "invocation_id": invocation_id,
            "user":          target.user,
        } %}
        {% set tag_json = tojson(tag) | replace("'", "''") %}
        {% set sql -%}
            ALTER SESSION SET QUERY_TAG = '{{ tag_json }}';
        {%- endset %}

        {% do log("Setting query_tag = " ~ tag_json, info=True) %}
        {% do run_query(sql) %}
    {% endif %}

{%- endmacro %}
