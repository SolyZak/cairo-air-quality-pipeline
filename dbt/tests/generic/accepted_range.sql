{% test accepted_range(model, column_name, min_value=none, max_value=none, inclusive=true) %}
{#-
    Fails for any row whose value falls outside [min_value, max_value].

    dbt ships `not_null`, `unique`, `accepted_values` and `relationships` --
    a range test normally comes from the dbt_utils package. Writing the fifteen
    lines here instead keeps the dependency list at zero, which matters for a
    project whose whole selling point is that `docker compose up` is the only
    setup step.

    NULLs pass. A missing reading is a separate concern, covered by not_null
    tests where a null is genuinely wrong; here, null means "the API had no
    data for this hour", which is not a range violation.
-#}

{%- set operator_low  = '<'  if inclusive else '<=' -%}
{%- set operator_high = '>'  if inclusive else '>=' -%}

select {{ column_name }} as offending_value
from {{ model }}
where {{ column_name }} is not null
  and (
    {%- if min_value is not none %}
        {{ column_name }} {{ operator_low }} {{ min_value }}
    {%- endif %}
    {%- if min_value is not none and max_value is not none %} or {% endif %}
    {%- if max_value is not none %}
        {{ column_name }} {{ operator_high }} {{ max_value }}
    {%- endif %}
  )

{% endtest %}
