variable "region" {
  description = <<-EOT
    us-east-1 by default because it is consistently the cheapest region, and
    this is a nightly batch job where latency to Cairo is irrelevant. Moving it
    closer (me-central-1) costs noticeably more for no benefit.
  EOT
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "project_name" {
  type    = string
  default = "cairo-air-quality"
}

variable "budget_alert_email" {
  description = "Where budget alarms are sent. Required -- see budget.tf for why."
  type        = string
}

variable "monthly_budget_usd" {
  description = <<-EOT
    The whole estate is designed to sit near $16/month with scheduled
    start/stop. 25 is a deliberate ceiling: high enough not to cry wolf, low
    enough that a mistake (an accidental NAT gateway, an instance left running)
    trips it within days rather than at the end of the month.
  EOT
  type        = number
  default     = 25
}

variable "admin_cidr" {
  description = <<-EOT
    The only address allowed to reach SSH and the Airflow UI. Your home IP as
    a /32, e.g. "203.0.113.4/32". Find it with: curl -s https://checkip.amazonaws.com

    Never set this to 0.0.0.0/0. An Airflow UI open to the internet is a
    remote code execution endpoint with a login form in front of it.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}
