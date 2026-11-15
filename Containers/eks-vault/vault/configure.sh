#!/bin/sh
# Run this INSIDE the vault-0 pod:
#   kubectl -n vault cp vault/configure.sh vault-0:/tmp/configure.sh
#   kubectl -n vault exec -it vault-0 -- sh /tmp/configure.sh
#
# Assumes Vault is in dev mode with root token "root".

set -eu

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"

echo ">> Enabling Kubernetes auth"
vault auth enable kubernetes || true
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

echo ">> Enabling database secrets engine"
vault secrets enable database || true

echo ">> Configuring Postgres connection"
vault write database/config/appdb \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgres.app.svc.cluster.local:5432/appdb?sslmode=disable" \
  username="postgres" \
  password="rootpw"

echo ">> Creating app-role (1m TTL so rotation is visible)"
vault write database/roles/app-role \
  db_name=appdb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE appdb TO \"{{name}}\";" \
  default_ttl="1m" \
  max_ttl="5m"

echo ">> Writing policy app-policy"
vault policy write app-policy - <<'EOF'
path "database/creds/app-role" {
  capabilities = ["read"]
}
EOF

echo ">> Binding app-sa (namespace: app) -> app-policy"
vault write auth/kubernetes/role/app-role \
  bound_service_account_names=app-sa \
  bound_service_account_namespaces=app \
  policies=app-policy \
  ttl=1h

echo ">> Smoke test: reading database/creds/app-role"
vault read database/creds/app-role

echo ">> Done."
