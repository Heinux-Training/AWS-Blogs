###############################################################################
# AWS Workload Account
# - VPC (private, no IGW/NAT)
# - Private subnet
# - VGW attached to VPC
# - S3 bucket (private, versioned)
# - Interface Endpoint for S3 with Private DNS enabled
# - Endpoint SG (allows 443 from on-prem CIDR)
# - Customer Gateway pointing at the strongSwan EIP in the on-prem account
# - Site-to-Site VPN connection (static routing)
###############################################################################

resource "aws_vpc" "workload" {
  provider             = aws.aws
  cidr_block           = var.aws_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "workload-vpc" }
}

resource "aws_subnet" "workload_private" {
  provider          = aws.aws
  vpc_id            = aws_vpc.workload.id
  cidr_block        = var.aws_private_subnet_cidr
  availability_zone = "${var.region}a"

  tags = { Name = "workload-private" }
}

resource "aws_route_table" "workload_private" {
  provider = aws.aws
  vpc_id   = aws_vpc.workload.id

  # Enable VGW route propagation so the on-prem CIDR is learned automatically
  propagating_vgws = [aws_vpn_gateway.workload.id]

  tags = { Name = "workload-private-rt" }
}

resource "aws_route_table_association" "workload_private" {
  provider       = aws.aws
  subnet_id      = aws_subnet.workload_private.id
  route_table_id = aws_route_table.workload_private.id
}

# ---- Virtual Private Gateway ------------------------------------------------
resource "aws_vpn_gateway" "workload" {
  provider = aws.aws
  vpc_id   = aws_vpc.workload.id

  tags = { Name = "workload-vgw" }
}

# ---- S3 bucket --------------------------------------------------------------
# S3 bucket names are globally unique, so append a random suffix.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
  provider      = aws.aws
  bucket        = "${var.bucket_name}-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "private-s3-demo" }
}

resource "aws_s3_bucket_public_access_block" "demo" {
  provider                = aws.aws
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "demo" {
  provider = aws.aws
  bucket   = aws_s3_bucket.demo.id
  versioning_configuration { status = "Enabled" }
}

# Cross-account access: grant the on-prem client role read access to this
# bucket. Cross-account S3 requires BOTH a bucket policy (here) and an
# identity policy on the role (aws_iam_role_policy.client_s3 in onprem.tf).
resource "aws_s3_bucket_policy" "demo" {
  provider = aws.aws
  bucket   = aws_s3_bucket.demo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOnPremClientRole"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.client.arn }
      Action    = ["s3:ListBucket", "s3:GetObject"]
      Resource = [
        aws_s3_bucket.demo.arn,
        "${aws_s3_bucket.demo.arn}/*"
      ]
    }]
  })

  # The public-access-block must exist first, otherwise the PutBucketPolicy
  # can race with restrict_public_buckets evaluation.
  depends_on = [aws_s3_bucket_public_access_block.demo]
}

resource "aws_s3_object" "hello" {
  provider     = aws.aws
  bucket       = aws_s3_bucket.demo.id
  key          = "test.txt"
  content      = "hello from the interface endpoint\n"
  content_type = "text/plain"
}

# ---- Security group for the endpoint ENI ------------------------------------
resource "aws_security_group" "endpoint" {
  provider    = aws.aws
  name        = "s3-endpoint-sg"
  description = "Allow HTTPS from the on-prem CIDR to the S3 Interface Endpoint"
  vpc_id      = aws_vpc.workload.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.onprem_vpc_cidr]
    description = "HTTPS from on-prem"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "s3-endpoint-sg" }
}

# ---- Interface Endpoint for S3 ---------------------------------------------
resource "aws_vpc_endpoint" "s3_interface" {
  provider            = aws.aws
  vpc_id              = aws_vpc.workload.id
  service_name        = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.workload_private.id]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true

  # Apply private DNS to all traffic (not just inbound resolver endpoints),
  # so the on-prem client resolves S3 to the endpoint over the VPN.
  # Setting this to true would require a separate S3 gateway endpoint.
  dns_options {
    private_dns_only_for_inbound_resolver_endpoint = false
  }

  tags = { Name = "s3-interface-endpoint" }
}

# ---- Customer Gateway (points at the on-prem EIP) ---------------------------
resource "aws_customer_gateway" "onprem" {
  provider   = aws.aws
  bgp_asn    = 65000
  ip_address = aws_eip.strongswan.public_ip
  type       = "ipsec.1"

  tags = { Name = "onprem-cgw" }
}

# ---- Site-to-Site VPN (static routing) --------------------------------------
resource "aws_vpn_connection" "main" {
  provider            = aws.aws
  vpn_gateway_id      = aws_vpn_gateway.workload.id
  customer_gateway_id = aws_customer_gateway.onprem.id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = { Name = "onprem-to-aws" }
}

resource "aws_vpn_connection_route" "onprem" {
  provider               = aws.aws
  destination_cidr_block = var.onprem_vpc_cidr
  vpn_connection_id      = aws_vpn_connection.main.id
}
