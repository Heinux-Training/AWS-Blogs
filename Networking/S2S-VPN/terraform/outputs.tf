output "strongswan_public_ip" {
  description = "EIP of the strongSwan EC2 in the on-prem account (used as CGW address)."
  value       = aws_eip.strongswan.public_ip
}

output "ssh_private_key_pem" {
  description = "Generated private key for SSH (sensitive). Also written to <key_pair_name>.pem."
  value       = tls_private_key.onprem.private_key_pem
  sensitive   = true
}

output "ssh_private_key_path" {
  description = "Local path to the generated private key file."
  value       = local_sensitive_file.onprem_private_key.filename
}

output "strongswan_ssh_command" {
  description = "Ready-to-use SSH command for the strongSwan instance."
  value       = "ssh -i ${local_sensitive_file.onprem_private_key.filename} ec2-user@${aws_eip.strongswan.public_ip}"
}

output "client_public_ip" {
  description = "Public IP of the client EC2 you SSH into to test S3 access."
  value       = aws_instance.client.public_ip
}

output "vpn_connection_id" {
  description = "Site-to-Site VPN connection ID (fetch tunnel details via the AWS console)."
  value       = aws_vpn_connection.main.id
}

output "vpn_tunnel1_address" {
  description = "AWS-side public IP of tunnel 1."
  value       = aws_vpn_connection.main.tunnel1_address
}

output "vpn_tunnel2_address" {
  description = "AWS-side public IP of tunnel 2."
  value       = aws_vpn_connection.main.tunnel2_address
}

output "vpn_tunnel1_psk" {
  description = "Pre-shared key for tunnel 1 (sensitive)."
  value       = aws_vpn_connection.main.tunnel1_preshared_key
  sensitive   = true
}

output "vpn_tunnel2_psk" {
  description = "Pre-shared key for tunnel 2 (sensitive)."
  value       = aws_vpn_connection.main.tunnel2_preshared_key
  sensitive   = true
}

output "s3_bucket_name" {
  description = "Bucket name to test against from the on-prem client."
  value       = aws_s3_bucket.demo.bucket
}

output "s3_endpoint_dns" {
  description = "DNS entries of the S3 Interface Endpoint (use to verify Private DNS resolution)."
  value       = aws_vpc_endpoint.s3_interface.dns_entry
}
