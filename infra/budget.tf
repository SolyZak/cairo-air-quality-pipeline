# ---------------------------------------------------------------------------
# The budget alarm is deliberately the first file in this stack.
#
# The failure mode that ruins cloud side-projects is not a wrong instance type,
# it is a resource nobody remembers creating, quietly billing for five weeks.
# A budget does not prevent spend -- nothing does -- but it converts a silent
# problem into an email on day two.
#
# AWS Budgets gives two free budgets per account, so this costs nothing.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Fires when spend so far this month passes half the ceiling. Early enough to
  # investigate while it is still cheap to be wrong.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # FORECASTED, not ACTUAL: this is the one that catches a NAT gateway on the
  # morning you create it, rather than three weeks later when the spend has
  # actually landed. It is the difference between a $2 mistake and a $30 one.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
