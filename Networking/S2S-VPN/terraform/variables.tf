variable "region" {
  description = "AWS region to deploy both accounts into."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_profile" {
  description = "AWS CLI profile for the workload account (S3 + endpoint + VGW)."
  type        = string
  default     = "aws-workload"
}

variable "onprem_account_profile" {
  description = "AWS CLI profile for the account simulating on-prem."
  type        = string
  default     = "onprem-sim"
}

variable "aws_vpc_cidr" {
  description = "CIDR for the AWS workload VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "aws_private_subnet_cidr" {
  description = "Private subnet in the AWS workload VPC."
  type        = string
  default     = "10.0.1.0/24"
}

variable "onprem_vpc_cidr" {
  description = "CIDR for the on-prem simulation VPC."
  type        = string
  default     = "10.100.0.0/16"
}

variable "onprem_public_subnet_cidr" {
  description = "Public subnet in the on-prem VPC (hosts strongSwan + client)."
  type        = string
  default     = "10.100.1.0/24"
}

variable "key_pair_name" {
  description = "Name for the EC2 key pair Terraform creates in the on-prem account for SSH."
  type        = string
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.4/32) — used to allow SSH to the on-prem EC2."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for the demo."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for both strongSwan and client hosts."
  type        = string
  default     = "t3.micro"
}
