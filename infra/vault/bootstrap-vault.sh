
#!/bin/sh
set -eu

# Required environment variables. Never hard-code real secrets here.
: "${AUTH_DB_PASSWORD:?Set AUTH_DB_PASSWORD}"
: "${TX_DB_PASSWORD:?Set TX_DB_PASSWORD}"
: "${SECRET_KEY:?Set SECRET_KEY}"
: "${SESSION_SECRET:?Set SESSION_SECRET}"

# Required Kubernetes service-account configuration.
: "${KUBERNETES_PORT_443_TCP_ADDR:?Kubernetes API address is unavailable}"

SA_TOKEN="/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

if [ ! -r "$SA_TOKEN" ] || [ ! -r "$SA_CA" ]; then
  echo "ERROR: Kubernetes service-account token or CA certificate is unavailable." >&2
  exit 1
fi

echo "==> Enabling Kubernetes auth if needed"
if ! vault auth list -format=json | grep -q '"kubernetes/":'; then
  vault auth enable kubernetes
fi

echo "==> Configuring Kubernetes auth"
vault write auth/kubernetes/config \
  token_reviewer_jwt=@"$SA_TOKEN" \
  kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443" \
  kubernetes_ca_cert=@"$SA_CA"

echo "==> Enabling KV v2 secrets engine if needed"
if ! vault secrets list -format=json | grep -q '"secureflow/":'; then
  vault secrets enable -path=secureflow kv-v2
fi

echo "==> Creating SecureFlow secrets"

vault kv put secureflow/auth-service \
  SECRET_KEY="$SECRET_KEY" \
  DB_HOST="auth-db" \
  DB_PORT="5432" \
  DB_NAME="authdb" \
  DB_USER="authuser" \
  DB_PASSWORD="$AUTH_DB_PASSWORD"

vault kv put secureflow/transaction-service \
  DB_HOST="transaction-db" \
  DB_PORT="5432" \
  DB_NAME="transactiondb" \
  DB_USER="txuser" \
  DB_PASSWORD="$TX_DB_PASSWORD"

vault kv put secureflow/frontend \
  AUTH_SERVICE_URL="http://auth-service:5001" \
  TRANSACTION_SERVICE_URL="http://transaction-service:5002" \
  SESSION_SECRET="$SESSION_SECRET"

echo "==> Creating Vault policies"

umask 077

cat > /tmp/auth-service-policy.hcl <<'EOF'
path "secureflow/data/auth-service" {
  capabilities = ["read"]
}
EOF

cat > /tmp/transaction-service-policy.hcl <<'EOF'
path "secureflow/data/transaction-service" {
  capabilities = ["read"]
}
EOF

cat > /tmp/frontend-policy.hcl <<'EOF'
path "secureflow/data/frontend" {
  capabilities = ["read"]
}
EOF

vault policy write auth-service-policy /tmp/auth-service-policy.hcl
vault policy write transaction-service-policy /tmp/transaction-service-policy.hcl
vault policy write frontend-policy /tmp/frontend-policy.hcl

rm -f /tmp/auth-service-policy.hcl \
  /tmp/transaction-service-policy.hcl \
  /tmp/frontend-policy.hcl

echo "==> Creating or updating Kubernetes auth roles"

vault write auth/kubernetes/role/auth-service \
  bound_service_account_names=auth-service-sa \
  bound_service_account_namespaces=secureflow \
  policies=auth-service-policy \
  ttl=1h

vault write auth/kubernetes/role/transaction-service \
  bound_service_account_names=transaction-service-sa \
  bound_service_account_namespaces=secureflow \
  policies=transaction-service-policy \
  ttl=1h

vault write auth/kubernetes/role/frontend \
  bound_service_account_names=frontend-sa \
  bound_service_account_namespaces=secureflow \
  policies=frontend-policy \
  ttl=1h

echo "==> Vault bootstrap complete"
echo "==> Configured roles:"
vault list auth/kubernetes/role
