{# ============================================================================
   test_positive_value.sql
   ----------------------------------------------------------------------------
   Generic dbt test. Fails if any row in `column_name` is <= 0.

       columns:
         - name: loan_amount
           tests:
             - positive_value
   ============================================================================ #}

{% test positive_value(model, column_name) %}

    select *
    from {{ model }}
    where {{ column_name }} is not null
      and {{ column_name }} <= 0

{% endtest %}
