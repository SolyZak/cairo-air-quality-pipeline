output "raw_bucket" {
  description = "S3 bucket raw API payloads are written to."
  value       = aws_s3_bucket.raw.id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "RDS lives here. No route to the internet."
  value       = aws_subnet.private[*].id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.app.name
}
