{# ============================================================================
   convert_to_usd.sql
   ----------------------------------------------------------------------------
   Reusable FX conversion macro. Usage in a model:

       select
             amount
           , {{ convert_to_usd('amount', 'currency', 'transaction_date') }}
                                                              as amount_usd
       from ...

   Uses the seed `exchange_rates` keyed by (currency, effective_month).
   Falls back to 1.0 (i.e. assumes USD) if no rate is found.
   ============================================================================ #}

{% macro convert_to_usd(amount_col, currency_col, date_col) -%}
    round(
        {{ amount_col }} * (
            select coalesce(max(fx.rate_to_usd), 1.0)
            from   {{ ref('exchange_rates') }} fx
            where  fx.currency        = {{ currency_col }}
              and  fx.effective_month = date_trunc('month', {{ date_col }})::date
        )
    , 2)
{%- endmacro %}
