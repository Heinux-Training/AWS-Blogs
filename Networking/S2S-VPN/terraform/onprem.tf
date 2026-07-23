###############################################################################
# On-Prem Simulation Account
# - VPC with IGW
# - Public subnet
# - Elastic IP (used as the Customer Gateway address on the AWS side)
# - strongSwan EC2 (VPN endpoint) with source/dest check disabled + IP forwarding
# - Client EC2 (runs aws s3 commands over the tunnel)
###############################################################################

data "aws_ami" "al2023" {
  provider    = aws.onprem
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_vpc" "onprem" {
  provider             = aws.onprem
  cidr_block           = var.onprem_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "onprem-vpc" }
}

resource "aws_internet_gateway" "onprem" {
  provider = aws.onprem
  vpc_id   = aws_vpc.onprem.id

  tags = { Name = "onprem-igw" }
}

resource "aws_subnet" "onprem_public" {
  provider                = aws.onprem
  vpc_id                  = aws_vpc.onprem.id
  cidr_block              = var.onprem_public_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = { Name = "onprem-public" }
}

resource "aws_route_table" "onprem_public" {
  provider = aws.onprem
  vpc_id   = aws_vpc.onprem.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.onprem.id
  }

  tags = { Name = "onprem-public-rt" }
}

resource "aws_route_table_association" "onprem_public" {
  provider       = aws.onprem
  subnet_id      = aws_subnet.onprem_public.id
  route_table_id = aws_route_table.onprem_public.id
}

# Route AWS-side traffic through the strongSwan ENI
resource "aws_route" "to_aws_via_strongswan" {
  provider               = aws.onprem
  route_table_id         = aws_route_table.onprem_public.id
  destination_cidr_block = var.aws_vpc_cidr
  network_interface_id   = aws_instance.strongswan.primary_network_interface_id
}

# ---- Elastic IP for strongSwan ---------------------------------------------
resource "aws_eip" "strongswan" {
  provider = aws.onprem
  domain   = "vpc"

  tags = { Name = "strongswan-eip" }
}

resource "aws_eip_association" "strongswan" {
  provider      = aws.onprem
  instance_id   = aws_instance.strongswan.id
  allocation_id = aws_eip.strongswan.id
}

# ---- Security groups --------------------------------------------------------
resource "aws_security_group" "strongswan" {
  provider    = aws.onprem
  name        = "strongswan-sg"
  description = "Allow IPsec (UDP 500/4500 + ESP) + SSH + intra-VPC"
  vpc_id      = aws_vpc.onprem.id

  ingress {
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "IKE"
  }
  ingress {
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "IPsec NAT-T"
  }
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "50" # ESP
    cidr_blocks = ["0.0.0.0/0"]
    description = "ESP"
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "SSH from my IP"
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.onprem_vpc_cidr]
    description = "All from within on-prem VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "strongswan-sg" }
}

resource "aws_security_group" "client" {
  provider    = aws.onprem
  name        = "onprem-client-sg"
  description = "Client host - SSH from my IP, all egress"
  vpc_id      = aws_vpc.onprem.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "SSH from my IP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "onprem-client-sg" }
}

# ---- strongSwan EC2 ---------------------------------------------------------
resource "aws_instance" "strongswan" {
  provider                    = aws.onprem
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.onprem_public.id
  vpc_security_group_ids      = [aws_security_group.strongswan.id]
  key_name                    = aws_key_pair.onprem.key_name
  source_dest_check           = false
  associate_public_ip_address = true

  # user_data installs libreswan and templates the full IPsec config from the
  # VPN connection's tunnel addresses + PSKs, so the tunnels come up on their
  # own after `terraform apply` — no manual /etc/ipsec.conf editing required.
  user_data = templatefile("${path.module}/strongswan-userdata.sh.tftpl", {
    strongswan_ip   = aws_eip.strongswan.public_ip
    onprem_cidr     = var.onprem_vpc_cidr
    aws_cidr        = var.aws_vpc_cidr
    tunnel1_address = aws_vpn_connection.main.tunnel1_address
    tunnel2_address = aws_vpn_connection.main.tunnel2_address
    tunnel1_psk     = aws_vpn_connection.main.tunnel1_preshared_key
    tunnel2_psk     = aws_vpn_connection.main.tunnel2_preshared_key
  })

  # Re-run user_data if the tunnel details change (e.g. VPN connection replaced).
  user_data_replace_on_change = true

  tags = { Name = "strongswan" }
}

# ---- Client EC2 -------------------------------------------------------------
resource "aws_iam_role" "client" {
  provider = aws.onprem
  name     = "onprem-client-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "client" {
  provider = aws.onprem
  name     = "onprem-client-profile"
  role     = aws_iam_role.client.name
}

# Identity-based policy so the client role may read the demo bucket.
# Cross-account S3 needs BOTH this AND a bucket policy naming the role
# (see aws_s3_bucket_policy.demo in aws-workload.tf).
resource "aws_iam_role_policy" "client_s3" {
  provider = aws.onprem
  name     = "s3-demo-access"
  role     = aws_iam_role.client.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:ListBucket", "s3:GetObject"]
      Resource = [
        aws_s3_bucket.demo.arn,
        "${aws_s3_bucket.demo.arn}/*"
      ]
    }]
  })
}

resource "aws_instance" "client" {
  provider               = aws.onprem
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.onprem_public.id
  vpc_security_group_ids = [aws_security_group.client.id]
  key_name               = aws_key_pair.onprem.key_name
  iam_instance_profile   = aws_iam_instance_profile.client.name

  user_data = <<-EOF
              #!/bin/bash
              set -eux
              dnf install -y awscli bind-utils
              EOF

  tags = { Name = "onprem-client" }
}
