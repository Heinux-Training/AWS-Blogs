terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# AWS workload account (the one holding S3 + Interface Endpoint + VGW)
provider "aws" {
  alias   = "aws"
  region  = var.region
  profile = var.aws_account_profile
}

# On-prem simulation account (VPC + IGW + strongSwan EC2 + client EC2)
provider "aws" {
  alias   = "onprem"
  region  = var.region
  profile = var.onprem_account_profile
}
