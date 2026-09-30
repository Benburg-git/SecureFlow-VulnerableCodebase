# Allow auth-service to read its own KV v2 secrets
path "secureflow/data/auth-service" {
  capabilities = ["read"]
}

# Allow metadata access for the auth-service secret
path "secureflow/metadata/auth-service" {
  capabilities = ["read"]
}