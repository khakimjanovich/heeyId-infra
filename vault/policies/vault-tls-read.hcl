# Reads Vault's own listener certificate and key (secret/tls/vault), which scripts/stack.sh writes to
# Vault's volume. Only the operator's short render token gets it (helpers' render_token).
path "secret/data/tls/vault" {
  capabilities = ["read"]
}
