# Vault as a server (scripts/stack.sh): data on the vault-data volume (Raft), sealed at every start,
# initialised and unsealed by its operators, by hand (docs/vault.md, "Vault").
storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

# TLS only: the console and the operators' CLI.
# The certificate is from heeyID's own CA (vault/tofu, secret/tls/vault); before that CA exists,
# a self-signed one made by scripts/stack.sh. stack.sh writes them to the vault-tls volume (the CA to
# vault-ca) and sends SIGHUP, which reloads them without sealing Vault.
listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/vault/tls/server.pem"
  tls_key_file    = "/vault/tls/server-key.pem"
  tls_min_version = "tls12"
}

api_addr      = "https://vault:8200"
cluster_addr  = "https://vault:8201"
disable_mlock = true # Raft's recommendation: mlock does not cover its memory-mapped files
ui            = true
