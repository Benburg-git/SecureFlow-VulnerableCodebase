
#!/bin/bash
set -Eeuo pipefail

CLUSTER_NAME="secureflow"
NAMESPACE="secureflow"
VAULT_NAMESPACE="vault"

echo "=========================================="
echo " SecureFlow Kubernetes Environment"
echo "=========================================="

echo ""
echo "=== Pre-flight: Checking required tools ==="

for cmd in docker kubectl kind helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is not installed or not available in PATH."
    exit 1
  fi
done

echo "Docker:  OK"
echo "kubectl: OK"
echo "Kind:    OK"
echo "Helm:    OK"

# Require secrets from the environment; never hard-code them here.
: "${AUTH_DB_PASSWORD:?Set AUTH_DB_PASSWORD before running this script}"
: "${TX_DB_PASSWORD:?Set TX_DB_PASSWORD before running this script}"
: "${SECRET_KEY:?Set SECRET_KEY before running this script}"
: "${SESSION_SECRET:?Set SESSION_SECRET before running this script}"

echo "Required secret variables: present"

echo ""
echo "=== Phase 1: Cluster, images, base manifests ==="

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Kind cluster '$CLUSTER_NAME' already exists."
else
  echo "Creating Kind cluster '$CLUSTER_NAME'..."
  kind create cluster --name "$CLUSTER_NAME"
fi

kubectl config use-context "kind-$CLUSTER_NAME"
kubectl get nodes

echo ""
echo "=== Building application images ==="

docker build -t secureflow/auth-service:latest ./services/auth-service
docker build -t secureflow/transaction-service:latest ./services/transaction-service
docker build -t secureflow/frontend:latest ./services/frontend

echo ""
echo "=== Loading images into Kind ==="

kind load docker-image secureflow/auth-service:latest --name "$CLUSTER_NAME"
kind load docker-image secureflow/transaction-service:latest --name "$CLUSTER_NAME"
kind load docker-image secureflow/frontend:latest --name "$CLUSTER_NAME"

echo ""
echo "=== Validating Kubernetes manifests ==="

if [ ! -d "infra/kubernetes/base" ]; then
  echo "ERROR: infra/kubernetes/base/ does not exist."
  exit 1
fi

if [ ! -f "infra/kubernetes/base/kustomization.yaml" ] &&
   [ ! -f "infra/kubernetes/base/kustomization.yml" ]; then
  echo "ERROR: No Kustomize file found in infra/kubernetes/base/."
  exit 1
fi

kubectl apply -k infra/kubernetes/base/

echo ""
echo "Waiting for base resources..."
sleep 15

echo ""
echo "=== Phase 2: Vault ==="

helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

if helm list -n "$VAULT_NAMESPACE" -q 2>/dev/null | grep -qx "vault"; then
  echo "Vault release already exists."
else
  echo "Installing Vault in DEV mode for local lab use only..."
  helm install vault hashicorp/vault \
    --set='server.dev.enabled=true' \
    --namespace "$VAULT_NAMESPACE" \
    --create-namespace
fi

kubectl wait \
  --namespace "$VAULT_NAMESPACE" \
  --for=condition=Ready \
  pod/vault-0 \
  --timeout=180s

echo ""
echo "=== Creating SecureFlow service accounts ==="

kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

for sa in auth-service-sa transaction-service-sa frontend-sa; do
  kubectl create serviceaccount "$sa" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "=== Configuring Vault Kubernetes authentication ==="

# Values are passed over stdin instead of being expanded inside the
# remote shell command. Do not enable shell tracing when handling secrets.
kubectl exec -i -n "$VAULT_NAMESPACE" vault-0 -- sh -c '
set -eu

vault auth enable kubernetes 2>/dev/null || true

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

vault secrets enable -path=secureflow kv-v2 2>/dev/null || true

IFS= read -r AUTH_DB_PASSWORD
IFS= read -r TX_DB_PASSWORD
IFS= read -r SECRET_KEY
IFS= read -r SESSION_SECRET

vault kv put secureflow/auth-service \
  DB_HOST="auth-db" \
  DB_PORT="5432" \
  DB_NAME="authdb" \
  DB_USER="authuser" \
  DB_PASSWORD="$AUTH_DB_PASSWORD" \
  SECRET_KEY="$SECRET_KEY"

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

vault policy write auth-service-policy - <<EOF
path "secureflow/data/auth-service" {
  capabilities = ["read"]
}
EOF

vault policy write transaction-service-policy - <<EOF
path "secureflow/data/transaction-service" {
  capabilities = ["read"]
}
EOF

vault policy write frontend-policy - <<EOF
path "secureflow/data/frontend" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/auth-service-role \
  bound_service_account_names=auth-service-sa \
  bound_service_account_namespaces=secureflow \
  policies=auth-service-policy \
  ttl=1h

vault write auth/kubernetes/role/transaction-service-role \
  bound_service_account_names=transaction-service-sa \
  bound_service_account_namespaces=secureflow \
  policies=transaction-service-policy \
  ttl=1h

vault write auth/kubernetes/role/frontend-role \
  bound_service_account_names=frontend-sa \
  bound_service_account_namespaces=secureflow \
  policies=frontend-policy \
  ttl=1h

vault audit enable file \
  file_path=/vault/logs/audit.log \
  2>/dev/null || echo "WARNING: Vault file audit device was not enabled."
' < <(printf '%s\n' \
  "$AUTH_DB_PASSWORD" \
  "$TX_DB_PASSWORD" \
  "$SECRET_KEY" \
  "$SESSION_SECRET")

echo ""
echo "=== Restarting SecureFlow database deployments ==="

kubectl rollout restart deployment/auth-db -n "$NAMESPACE"
kubectl rollout restart deployment/transaction-db -n "$NAMESPACE"

echo ""
echo "=== Waiting for SecureFlow databases ==="

kubectl rollout status deployment/auth-db \
  -n "$NAMESPACE" --timeout=180s

kubectl rollout status deployment/transaction-db \
  -n "$NAMESPACE" --timeout=180s

echo ""
echo "=== Restarting SecureFlow applications ==="

kubectl rollout restart deployment/auth-service -n "$NAMESPACE"
kubectl rollout restart deployment/transaction-service -n "$NAMESPACE"
kubectl rollout restart deployment/frontend -n "$NAMESPACE"

echo ""
echo "=== Waiting for SecureFlow applications ==="

kubectl rollout status deployment/auth-service \
  -n "$NAMESPACE" --timeout=180s

kubectl rollout status deployment/transaction-service \
  -n "$NAMESPACE" --timeout=180s

kubectl rollout status deployment/frontend \
  -n "$NAMESPACE" --timeout=180s

echo ""
echo "=== Phase 3: Gatekeeper and Falco ==="

helm repo add gatekeeper \
  https://open-policy-agent.github.io/gatekeeper/charts \
  2>/dev/null || true

helm repo add falcosecurity \
  https://falcosecurity.github.io/charts \
  2>/dev/null || true

helm repo update

if helm list -n gatekeeper-system -q 2>/dev/null | grep -qx "gatekeeper"; then
  echo "Gatekeeper release already exists."
else
  helm install gatekeeper gatekeeper/gatekeeper \
    --namespace gatekeeper-system \
    --create-namespace
fi

kubectl wait \
  --namespace gatekeeper-system \
  --for=condition=Ready \
  pod --all \
  --timeout=180s || echo "WARNING: Some Gatekeeper pods are not ready."

if [ -d "infra/kubernetes/gatekeeper" ]; then
  echo "Applying Gatekeeper ConstraintTemplates..."

  for file in infra/kubernetes/gatekeeper/*-template.yaml; do
    [ -f "$file" ] && kubectl apply -f "$file"
  done

  echo "Waiting for ConstraintTemplates to register..."
  sleep 10

  echo "Applying Gatekeeper constraints..."

  for file in infra/kubernetes/gatekeeper/*-constraint.yaml; do
    [ -f "$file" ] && kubectl apply -f "$file"
  done
else
  echo "WARNING: infra/kubernetes/gatekeeper/ not found."
fi

if [ ! -f "infra/kubernetes/falco/custom-rules.yaml" ]; then
  echo "ERROR: Falco custom rules file not found."
  exit 1
fi

if helm list -n falco -q 2>/dev/null | grep -qx "falco"; then
  echo "Falco release already exists."
else
  helm install falco falcosecurity/falco \
    --namespace falco \
    --create-namespace \
    --set driver.kind=modern_ebpf \
    --set collectors.containerEngine.enabled=true \
    --set falco.json_output=true \
    --set falco.json_include_output_property=true \
    --set-file customRules."secureflow_rules\.yaml"=infra/kubernetes/falco/custom-rules.yaml
fi

kubectl wait \
  --namespace falco \
  --for=condition=Ready \
  pod --all \
  --timeout=180s || echo "WARNING: Some Falco pods are not ready."

echo ""
echo "=========================================="
echo " SecureFlow deployment verification"
echo "=========================================="

echo ""
echo "=== Kubernetes nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== SecureFlow pods ==="
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "=== SecureFlow services ==="
kubectl get services -n "$NAMESPACE"

echo ""
echo "=== Vault pods ==="
kubectl get pods -n "$VAULT_NAMESPACE" -o wide

echo ""
echo "=== Gatekeeper pods ==="
kubectl get pods -n gatekeeper-system -o wide

echo ""
echo "=== Falco pods ==="
kubectl get pods -n falco -o wide

echo ""
echo "=== Helm releases ==="
helm list -A

echo ""
echo "=== Gatekeeper ConstraintTemplates ==="
kubectl get constrainttemplates 2>/dev/null || true

echo ""
echo "=== Gatekeeper constraint resource types ==="
kubectl api-resources \
  --api-group=constraints.gatekeeper.sh 2>/dev/null || true

echo ""
echo "=== Privileged container constraint ==="
kubectl get k8sdisallowprivileged 2>/dev/null || true

echo ""
echo "=== Root container constraint ==="
kubectl get k8sdisallowroot 2>/dev/null || true

echo ""
echo "=========================================="
echo " SecureFlow deployment script completed"
echo "=========================================="
