###############################################################################
# SSH key pair (generated on apply)
# - Generates an RSA key pair with the tls provider
# - Registers the public key as an EC2 key pair in the on-prem account
# - Writes the private key to disk (0600) and exposes it as a sensitive output
###############################################################################

resource "tls_private_key" "onprem" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "onprem" {
  provider   = aws.onprem
  key_name   = var.key_pair_name
  public_key = tls_private_key.onprem.public_key_openssh

  tags = { Name = var.key_pair_name }
}

# Save the private key locally so you can SSH in right after apply.
resource "local_sensitive_file" "onprem_private_key" {
  content         = tls_private_key.onprem.private_key_pem
  filename        = "${path.module}/${var.key_pair_name}.pem"
  file_permission = "0600"
}
