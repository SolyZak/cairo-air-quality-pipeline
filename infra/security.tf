# ---------------------------------------------------------------------------
# Security groups.
#
# The EC2 box is in a public subnet, so the security group is the only thing
# between the Airflow UI and the internet. Both inbound rules are pinned to
# var.admin_cidr -- a single address -- and variables.tf refuses 0.0.0.0/0
# outright. An Airflow UI reachable from anywhere is a remote code execution
# endpoint with a login form in front of it.
# ---------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app"
  description = "Airflow host: SSH and web UI from the admin address only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.app.id
  description       = "SSH from the admin address"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "airflow_ui" {
  security_group_id = aws_security_group.app.id
  description       = "Airflow web UI from the admin address"
  cidr_ipv4         = var.admin_cidr
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
}

# Outbound is open: the host has to reach the Open-Meteo API, Docker Hub and
# the AWS APIs. Restricting egress to specific prefixes is possible but would
# break on every upstream IP change, for little gain on a single-purpose box.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- database ---------------------------------------------------------------

resource "aws_security_group" "db" {
  name        = "${var.project_name}-db"
  description = "Postgres, reachable only from the application host"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-db" }
}

# Source is the app SECURITY GROUP, not a CIDR. This keeps working when the
# instance is replaced and its private IP changes -- which happens on every
# stop/start cycle, and this design stops and starts the box daily.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the Airflow host"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# Deliberately no egress rule. A database that cannot make outbound
# connections is one fewer way for a compromise to exfiltrate anything.
