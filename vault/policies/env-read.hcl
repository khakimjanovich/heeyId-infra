# Reads every service's settings (secret/env/*), for the operator's render token. Writes nothing.
path "secret/data/env/*" {
  capabilities = ["read"]
}
