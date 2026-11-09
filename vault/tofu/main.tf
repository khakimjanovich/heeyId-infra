# heeyID's Vault, as code: every mount, policy and role, and every service's settings (settings.tf).
# Not here: init, the unseal keys and the root token (the operator's, docs/vault.md, "Vault"). The
# state holds generated passwords and private keys, so it is encrypted with the operator's passphrase
# and never written in the clear. Run with (docs/vault.md, "Vault"):
#   VAULT_ADDR, VAULT_TOKEN and TF_VAR_state_passphrase from the environment; none has a default.
terraform {
  required_version = "1.10.6"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.passphrase
    }
    state {
      method   = method.aes_gcm.state
      enforced = true # never written unencrypted
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

# Keep it with the unseal keys: without it this state can't be read (Vault itself is unaffected).
variable "state_passphrase" {
  type      = string
  sensitive = true
  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}

# The consoles' domain, .env.local's CONSOLES_DOMAIN (the helpers' t passes it): people reach each
# console by its name under it through heeyid-consoles, and its certificate names that name.
variable "consoles_domain" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.consoles_domain))
    error_message = "CONSOLES_DOMAIN (.env.local) must be a DNS name with a dot, lower case, e.g. consoles.example.com."
  }
}

provider "vault" {}

# Settings, keyed by environment variable, at secret/env/<service> (docs/settings.md, "Settings").
resource "vault_mount" "secret" {
  path    = "secret"
  type    = "kv"
  options = { version = "2" }
}

# Every request, kept on the vault-audit volume.
resource "vault_audit" "file" {
  type    = "file"
  options = { file_path = "/vault/logs/audit.log" }
}

resource "vault_policy" "env_read" {
  name   = "env-read"
  policy = file("${path.module}/../policies/env-read.hcl")
}

resource "vault_policy" "vault_tls_read" {
  name   = "vault-tls-read"
  policy = file("${path.module}/../policies/vault-tls-read.hcl")
}

resource "vault_policy" "cert_watch" {
  name   = "cert-watch"
  policy = file("${path.module}/../policies/cert-watch.hcl")
}

# heeyID's CA: its key is made inside Vault and never leaves it.
resource "vault_mount" "pki" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10 years, the CA's own
  lifecycle { prevent_destroy = true }
}

resource "vault_pki_secret_backend_root_cert" "ca" {
  backend     = vault_mount.pki.path
  type        = "internal"
  common_name = "heeyid unit CA"
  ttl         = "87600h"
  lifecycle { prevent_destroy = true }
}

# heeyID's services: server-and-client certificates for their bare names on the `heeyid` network and
# their <name>.heeyid.internal names, each exactly (allow_subdomains off), 90 days at most.
resource "vault_pki_secret_backend_role" "heeyid_service" {
  backend                     = vault_mount.pki.path
  name                        = "heeyid-service"
  allowed_domains             = concat(sort(local.services), [for name in sort(local.services) : "${name}.${local.internal_domain}"])
  allow_bare_domains          = true
  allow_subdomains            = false
  allow_localhost             = false
  allow_ip_sans               = false
  allow_wildcard_certificates = false
  server_flag                 = true
  client_flag                 = true
  max_ttl                     = "7776000" # 90 days
  depends_on                  = [vault_pki_secret_backend_root_cert.ca]
}

# The adapters' callers inside heeyID (local.callers): client certificates only, for the name that is
# also the caller's client in realm services, 90 days at most. A caller's own deployable gets its
# certificate here when it is added to this repo.
resource "vault_pki_secret_backend_role" "callers" {
  backend                     = vault_mount.pki.path
  name                        = "callers"
  allowed_domains             = sort(local.callers)
  allow_bare_domains          = true
  allow_subdomains            = false
  allow_localhost             = false
  allow_ip_sans               = false
  allow_wildcard_certificates = false
  server_flag                 = false
  client_flag                 = true
  max_ttl                     = "7776000" # 90 days
  depends_on                  = [vault_pki_secret_backend_root_cert.ca]
}

# The consoles' listeners, Vault, Keycloak, Grafana and Mailpit: the names heeyID's containers use, and
# each one's name under CONSOLES_DOMAIN, which people reach it by (settings.tf, console_names); and
# 127.0.0.1, Vault's own CLI inside its container. Only OpenTofu issues with it.
resource "vault_pki_secret_backend_role" "consoles" {
  backend                     = vault_mount.pki.path
  name                        = "consoles"
  allowed_domains             = concat(keys(local.console_names), flatten(values(local.console_names)))
  allow_bare_domains          = true
  allow_subdomains            = false
  allow_localhost             = false
  allow_ip_sans               = true
  allow_wildcard_certificates = false
  server_flag                 = true
  client_flag                 = false
  max_ttl                     = "7776000" # 90 days
  depends_on                  = [vault_pki_secret_backend_root_cert.ca]
}
