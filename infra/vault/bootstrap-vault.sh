#!/bin/sh
set -e

echo "==> Enabling Kubernetes auth if needed"
vault auth list | grep -q '^kubernetes/' || vault auth enable kubernetes

echo "==> Configuring Kubernetes auth"
vault write auth/kubernetes/config token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443" kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

echo "==> Enabling KV v2 secrets engine if needed"
vault secrets list | grep -q '^secureflow/' || vault secrets enable -path=secureflow kv-v2

echo "==> Creating SecureFlow secrets"

vault kv put secureflow/auth-service SECRET_KEY="changeme" DB_HOST="auth-db" DB_PORT="5432" DB_NAME="authdb" DB_USER="authuser" DB_PASSWORD="authpass123"

vault kv put secureflow/transaction-service DB_HOST="transaction-db" DB_PORT="5432" DB_NAME="transactiondb" DB_USER="txuser" DB_PASSWORD="transactionpass123"

vault kv put secureflow/frontend AUTH_SERVICE_URL="http://auth-service:5001" TRANSACTION_SERVICE_URL="http://transaction-service:5002"

echo "==> Creating Vault policies"

cat >/tmp/auth-service-policy.hcl <<'EOF'
path "secureflow/data/auth-service" {
capabilities = ["read"]
}
EOF

cat >/tmp/transaction-service-policy.hcl <<'EOF'
path "secureflow/data/transaction-service" {
capabilities = ["read"]
}
EOF

cat >/tmp/frontend-policy.hcl <<'EOF'
path "secureflow/data/frontend" {
capabilities = ["read"]
}
EOF

vault policy write auth-service-policy /tmp/auth-service-policy.hcl
vault policy write transaction-service-policy /tmp/transaction-service-policy.hcl
vault policy write frontend-policy /tmp/frontend-policy.hcl

echo "==> Creating Kubernetes auth roles"

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
echo "==> Bootstrap complete"

vault list auth/kubernetes/role
