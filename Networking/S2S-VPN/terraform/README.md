# Private S3 from On-Prem — Terraform

Provisions both sides of the demo across two AWS accounts using provider aliases.

## Prerequisites

1. Two AWS accounts. Configure named CLI profiles for each in `~/.aws/credentials` (or SSO).
2. An EC2 key pair in the **on-prem** account, in the region you're deploying to.
3. Your public IP (for SSH allow-listing).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set profiles, key_pair_name, my_ip_cidr, bucket_name

terraform init
terraform apply
```

## After `apply` — tunnels come up automatically

No manual VPN config needed. The strongSwan EC2's user-data
([`strongswan-userdata.sh.tftpl`](./strongswan-userdata.sh.tftpl)) installs **libreswan**
(AL2023 has no `strongswan` package), templates `/etc/ipsec.d/aws.conf` +
`/etc/ipsec.d/aws.secrets` from the VPN connection's tunnel IPs and PSKs, and starts
the tunnels on first boot.

To watch the negotiation (optional):

```bash
ssh ec2-user@$(terraform output -raw strongswan_public_ip)
sudo ipsec status          # expect: loaded 2, active 1
sudo ipsec trafficstatus   # established tunnel + byte counters
sudo journalctl -u ipsec -f
```

`active 1` is correct — AWS keeps one tunnel up and one on standby for failover.

> **Crypto note:** AL2023's crypto-policy disables `modp1024` (DH group 2). The config
> uses DH group 14 (`modp2048`) with AES-256/SHA-256, which AWS accepts by default.

## Test

```bash
# From the client EC2 (SSH via client_public_ip). Replace the region to match yours.
# The regional S3 name resolves to PUBLIC IPs from on-prem (expected — see blog).
# Use /etc/hosts + getent, since `dig` ignores /etc/hosts:
ENDPOINT=$(dig +short vpce-xxxx.s3.<region>.vpce.amazonaws.com | head -1)
echo "$ENDPOINT s3.<region>.amazonaws.com" | sudo tee -a /etc/hosts
getent hosts s3.<region>.amazonaws.com   # should show 10.0.1.x

aws s3 ls s3://$(terraform output -raw s3_bucket_name)/ --endpoint-url https://s3.<region>.amazonaws.com
aws s3 cp s3://$(terraform output -raw s3_bucket_name)/test.txt -
```

Cross-account S3 access is granted by both an identity policy on the client role and a
bucket policy (both provisioned). The production DNS fix is a Route 53 Resolver inbound
endpoint in the workload VPC — see the blog post.

## Teardown

```bash
terraform destroy
```

The S3 bucket has `force_destroy = true` so versioned objects are removed.
