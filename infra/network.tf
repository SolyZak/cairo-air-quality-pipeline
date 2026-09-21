# ---------------------------------------------------------------------------
# Network.
#
# THE most important line in this whole repository is the one that is not here:
# there is no aws_nat_gateway. A NAT gateway is roughly $33/month before a byte
# of traffic -- more than every other resource in this stack combined, and more
# than the entire monthly budget. Most "production-shaped" AWS tutorials put
# private subnets behind one without mentioning the price.
#
# It is avoided like this:
#   * EC2 sits in a PUBLIC subnet and reaches the internet through the internet
#     gateway directly. Its security group, not a subnet boundary, is what
#     protects it.
#   * RDS sits in PRIVATE subnets with no route to the internet -- which is
#     fine, because a database has no reason to make outbound connections.
#   * S3 is reached through a VPC GATEWAY endpoint, which is free. (Interface
#     endpoints are not free, at ~$7/month each; gateway endpoints exist only
#     for S3 and DynamoDB and cost nothing.)
#
# Two AZs are not a resilience choice here -- a single-AZ RDS instance still
# requires a subnet group spanning at least two availability zones. AWS
# enforces it whether you want the redundancy or not.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # RDS endpoints are DNS names; without this they do not resolve.

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# --- public: the EC2 box ----------------------------------------------------

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- private: RDS only ------------------------------------------------------

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 11}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.project_name}-private-${count.index + 1}" }
}

# No 0.0.0.0/0 route. The only traffic in or out is within the VPC, plus S3 via
# the gateway endpoint below.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- S3 without paying for egress or a NAT ----------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]

  tags = { Name = "${var.project_name}-s3-endpoint" }
}
