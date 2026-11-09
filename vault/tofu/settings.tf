# Every service's settings, secret/env/<service>, which scripts/stack.sh renders before anything
# starts. Three kinds of value:
#   - this stack's own: addresses, ports, timeouts, the same in every environment (locals);
#   - generated here and written to both sides that must agree: passwords, client secrets, each
#     service's certificate (renewed by apply in its last 30 days);
#   - the environment's: what only its operator knows (MyID's hosts, the bank's collectors, mail, the
#     directory), read from secret/input/heeyid, which scripts/install.sh writes (docs/settings.md,
#     "Settings"); and each tenant's MyID credential, from secret/myid-tenants (scripts/install.sh
#     add-tenant). A key missing there stops plan.
# Rotating a generated value: `tofu apply -replace=<resource>`, then deploy.

data "vault_kv_secret_v2" "input" {
  mount = vault_mount.secret.path
  name  = "input/heeyid"
}

data "vault_kv_secret_v2" "myid_tenants" {
  mount = vault_mount.secret.path
  name  = "myid-tenants"
}

locals {
  input  = data.vault_kv_secret_v2.input.data
  issuer = "https://heeyid-keycloak:8443/realms/services"
  otlp = {
    TRACING_SAMPLING      = "1.0"
    OTLP_TRACES_ENDPOINT  = "http://observability:4318/v1/traces"
    OTLP_METRICS_ENDPOINT = "http://observability:4318/v1/metrics"
    OTLP_LOGS_ENDPOINT    = "http://observability:4318/v1/logs"
  }
  # heeyID's services, each with its certificate from heeyID's CA (role heeyid-service).
  services        = toset(["myid-adapter"])
  internal_domain = "heeyid.internal"
  # The MyID adapter's callers: heeyID's own clients in realm services (keycloak/services-realm.json),
  # each with the role myid.use and the audience myid-adapter. Their deployables come later; their
  # client secrets are generated now (secret/env/keycloak-config), their certificates come from role
  # callers.
  callers = toset(["customer-gateway", "workers"])
  # The consoles behind heeyid-consoles, each by its container's name, and the names its certificate
  # carries: its name under CONSOLES_DOMAIN (the door's, consoles/names.conf.stream-template).
  console_names = {
    "vault"           = ["vault.${var.consoles_domain}"]
    "observability"   = ["grafana.${var.consoles_domain}"]
    "heeyid-keycloak" = ["keycloak.${var.consoles_domain}"]
    "mailpit"         = ["mailpit.${var.consoles_domain}"]
  }
  # Each tenant's MyID credential, one key per tenant (its X-Tenant-Id), JSON {client-id,
  # client-secret, username, password}: the last two only for the Backend API without personal data,
  # empty without it. scripts/install.sh add-tenant writes it; the adapter reads it as a file
  # (myid.tenants, docker-compose.yml, myid-tenants).
  # The names are not secret; the credentials stay sensitive.
  myid_tenants = { for name in nonsensitive(keys(data.vault_kv_secret_v2.myid_tenants.data)) :
  name => jsondecode(data.vault_kv_secret_v2.myid_tenants.data[name]) }
  myid_tenants_yaml = yamlencode({ myid = { tenants = { for name, t in local.myid_tenants : name => merge(
    { client-id = t["client-id"], client-secret = t["client-secret"] },
    t["username"] == "" ? {} : { username = t["username"], password = t["password"] },
  ) } } })
  # The ship settings: an empty endpoint ships nothing of that kind.
  shipping = local.input["LOG_SHIP_PROTOCOL"] != "off" || local.input["METRICS_SHIP_ENDPOINT"] != "" || local.input["TRACES_SHIP_ENDPOINT"] != ""
}

resource "random_password" "this" {
  for_each = toset(["postgres", "keycloak-db", "keycloak-admin", "grafana-admin", "keycloak-config-client", "grafana-client", "valkey-myid-adapter"])
  length   = 32
  special  = false # values go into env files and JDBC URLs unquoted
}

# The AES-256 key of the MyID tokens in Valkey (SAD TB-5: cached in Valkey only encrypted).
resource "random_bytes" "myid_token_key" {
  length = 32
}

resource "random_password" "caller" {
  for_each = local.callers
  length   = 32
  special  = false
}

# Each service's server-and-client certificate from heeyID's CA; apply issues a new one in its last 30
# days (then deploy).
resource "vault_pki_secret_backend_cert" "this" {
  for_each              = local.services
  backend               = vault_mount.pki.path
  name                  = vault_pki_secret_backend_role.heeyid_service.name
  common_name           = each.key
  alt_names             = ["${each.key}.${local.internal_domain}"]
  ttl                   = "2160h"
  auto_renew            = true
  min_seconds_remaining = 2592000
}

# The consoles' certificates (role consoles, main.tf), renewed the same way.
resource "vault_pki_secret_backend_cert" "console" {
  for_each              = local.console_names
  backend               = vault_mount.pki.path
  name                  = vault_pki_secret_backend_role.consoles.name
  common_name           = each.key
  alt_names             = each.value
  ip_sans               = ["127.0.0.1"]
  ttl                   = "2160h"
  auto_renew            = true
  min_seconds_remaining = 2592000
}

# Vault's listener: scripts/stack.sh writes it to the vault-tls and vault-ca volumes and reloads Vault
# (SIGHUP). Not under env/: its key is for the operator's render token only (policy vault-tls-read).
resource "vault_kv_secret_v2" "vault_tls" {
  mount = vault_mount.secret.path
  name  = "tls/vault"
  data_json = jsonencode({
    VAULT_TLS_CERTIFICATE = vault_pki_secret_backend_cert.console["vault"].certificate
    VAULT_TLS_PRIVATE_KEY = vault_pki_secret_backend_cert.console["vault"].private_key
    VAULT_TLS_CA          = vault_pki_secret_backend_cert.console["vault"].issuing_ca
  })
}

# Mailpit's web console serves HTTPS too (consoles/mailpit-tls.sh); its settings are rendered whether
# MAILPIT is on or off.
resource "vault_kv_secret_v2" "mailpit" {
  mount = vault_mount.secret.path
  name  = "env/mailpit"
  data_json = jsonencode({
    MAILPIT_TLS_CERTIFICATE = vault_pki_secret_backend_cert.console["mailpit"].certificate
    MAILPIT_TLS_PRIVATE_KEY = vault_pki_secret_backend_cert.console["mailpit"].private_key
  })
}

resource "vault_kv_secret_v2" "stack" {
  mount = vault_mount.secret.path
  name  = "env/stack"
  data_json = jsonencode({
    MAILPIT            = local.input["MAILPIT"]
    PULL_ATTEMPTS      = local.input["PULL_ATTEMPTS"]
    PULL_RETRY_SECONDS = local.input["PULL_RETRY_SECONDS"]
  })
  lifecycle {
    precondition {
      condition     = alltrue([for k in ["PULL_ATTEMPTS", "PULL_RETRY_SECONDS"] : can(regex("^[1-9][0-9]*$", local.input[k]))])
      error_message = "PULL_ATTEMPTS, PULL_RETRY_SECONDS: whole numbers above 0 (how often deploy tries to pull an image, and the wait between tries)."
    }
  }
}

# Postgres holds Keycloak's database only, for now.
resource "vault_kv_secret_v2" "postgres" {
  mount = vault_mount.secret.path
  name  = "env/postgres"
  data_json = jsonencode({
    POSTGRES_PASSWORD    = random_password.this["postgres"].result
    KEYCLOAK_DB_PASSWORD = random_password.this["keycloak-db"].result
  })
}

# Valkey: the default user is off; each service has its own ACL user for its own keys
# (valkey/start.sh). Keys carry the tenant prefix first (SAD §6, "Cache"), then the service's name.
resource "vault_kv_secret_v2" "valkey" {
  mount = vault_mount.secret.path
  name  = "env/valkey"
  data_json = jsonencode({
    VALKEY_MYID_ADAPTER_PASSWORD = random_password.this["valkey-myid-adapter"].result
  })
}

resource "vault_kv_secret_v2" "keycloak" {
  mount = vault_mount.secret.path
  name  = "env/keycloak"
  data_json = jsonencode({
    KC_DB_PASSWORD              = random_password.this["keycloak-db"].result
    KC_BOOTSTRAP_ADMIN_PASSWORD = random_password.this["keycloak-admin"].result
    KEYCLOAK_TLS_CERTIFICATE    = vault_pki_secret_backend_cert.console["heeyid-keycloak"].certificate
    KEYCLOAK_TLS_PRIVATE_KEY    = vault_pki_secret_backend_cert.console["heeyid-keycloak"].private_key
    LDAP_TRUSTED_CAS            = local.input["LDAP_TRUSTED_CAS"] # the directory's CA (keycloak/tls.sh)
  })
}

# keycloak-config's own settings, apart from Keycloak's: a change here reruns keycloak-config only and
# never restarts Keycloak.
resource "vault_kv_secret_v2" "keycloak_config" {
  mount = vault_mount.secret.path
  name  = "env/keycloak-config"
  data_json = jsonencode(merge(
    { for c in local.callers : "${upper(replace(c, "-", "_"))}_CLIENT_SECRET" => random_password.caller[c].result },
    {
      KC_BOOTSTRAP_ADMIN_PASSWORD   = random_password.this["keycloak-admin"].result
      KEYCLOAK_TRUSTED_CAS          = vault_pki_secret_backend_cert.console["heeyid-keycloak"].issuing_ca # its kcadm
      MYID_ADAPTER_CALLERS          = join(",", sort(local.callers))
      KEYCLOAK_CONFIG_CLIENT_SECRET = random_password.this["keycloak-config-client"].result
      KEYCLOAK_KEY_ROTATE_DAYS      = local.input["KEYCLOAK_KEY_ROTATE_DAYS"]
      GRAFANA_CLIENT_SECRET         = random_password.this["grafana-client"].result
      # The consoles' people come from the bank's directory, read only (keycloak/configure.sh).
      LDAP_URL                 = local.input["LDAP_URL"]
      LDAP_VENDOR              = local.input["LDAP_VENDOR"]
      LDAP_BIND_DN             = local.input["LDAP_BIND_DN"]
      LDAP_BIND_PASSWORD       = local.input["LDAP_BIND_PASSWORD"]
      LDAP_USERS_DN            = local.input["LDAP_USERS_DN"]
      LDAP_USER_OBJECT_CLASSES = local.input["LDAP_USER_OBJECT_CLASSES"]
      LDAP_USERNAME_ATTRIBUTE  = local.input["LDAP_USERNAME_ATTRIBUTE"]
      LDAP_UUID_ATTRIBUTE      = local.input["LDAP_UUID_ATTRIBUTE"]
      LDAP_ADMINS_GROUP_DN     = local.input["LDAP_ADMINS_GROUP_DN"]
      LDAP_VIEWERS_GROUP_DN    = local.input["LDAP_VIEWERS_GROUP_DN"]
      CONSOLE_LOCKOUT_FAILURES = local.input["CONSOLE_LOCKOUT_FAILURES"]
      CONSOLE_LOCKOUT_MINUTES  = local.input["CONSOLE_LOCKOUT_MINUTES"]
      CONSOLE_IDLE_MINUTES     = local.input["CONSOLE_IDLE_MINUTES"]
  }))
  lifecycle {
    precondition {
      condition     = can(regex("^ldaps://", local.input["LDAP_URL"])) && strcontains(local.input["LDAP_TRUSTED_CAS"], "BEGIN CERTIFICATE") && local.input["LDAP_ADMINS_GROUP_DN"] != local.input["LDAP_VIEWERS_GROUP_DN"]
      error_message = "LDAP_URL: ldaps:// only, with LDAP_TRUSTED_CAS the directory's CA; LDAP_ADMINS_GROUP_DN and LDAP_VIEWERS_GROUP_DN two different groups."
    }
    precondition {
      condition     = can(regex("^[1-9][0-9]*$", local.input["KEYCLOAK_KEY_ROTATE_DAYS"])) && tonumber(local.input["KEYCLOAK_KEY_ROTATE_DAYS"]) <= 365
      error_message = "KEYCLOAK_KEY_ROTATE_DAYS: the token signing keys' cryptoperiod, 1 to 365 days."
    }
    precondition {
      condition     = can(regex("^([1-9]|10)$", local.input["CONSOLE_LOCKOUT_FAILURES"]))
      error_message = "CONSOLE_LOCKOUT_FAILURES: 1 to 10 failed sign-ins before the lockout."
    }
    precondition {
      condition     = can(regex("^[0-9]+$", local.input["CONSOLE_LOCKOUT_MINUTES"])) && tonumber(local.input["CONSOLE_LOCKOUT_MINUTES"]) >= 30
      error_message = "CONSOLE_LOCKOUT_MINUTES: 30 or more."
    }
    precondition {
      condition     = can(regex("^([1-9]|1[0-5])$", local.input["CONSOLE_IDLE_MINUTES"]))
      error_message = "CONSOLE_IDLE_MINUTES: 1 to 15 idle minutes before a session ends."
    }
  }
}

resource "vault_kv_secret_v2" "observability" {
  mount = vault_mount.secret.path
  name  = "env/observability"
  data_json = jsonencode({
    GF_SECURITY_ADMIN_PASSWORD = random_password.this["grafana-admin"].result
    GRAFANA_TLS_CERTIFICATE    = vault_pki_secret_backend_cert.console["observability"].certificate
    GRAFANA_TLS_PRIVATE_KEY    = vault_pki_secret_backend_cert.console["observability"].private_key
    GRAFANA_TRUSTED_CAS        = vault_pki_secret_backend_cert.console["observability"].issuing_ca # Keycloak's CA
    GF_SMTP_HOST               = local.input["GF_SMTP_HOST"]
    GF_SMTP_USER               = local.input["GF_SMTP_USER"]
    GF_SMTP_PASSWORD           = local.input["GF_SMTP_PASSWORD"]
    GF_SMTP_STARTTLS_POLICY    = local.input["GF_SMTP_STARTTLS_POLICY"]
    GF_SMTP_FROM_ADDRESS       = local.input["GF_SMTP_FROM_ADDRESS"]
    ALERT_EMAILS               = local.input["ALERT_EMAILS"]
    LOG_SHIP_PROTOCOL          = local.input["LOG_SHIP_PROTOCOL"]
    LOG_SHIP_ENDPOINT          = local.input["LOG_SHIP_ENDPOINT"]
    METRICS_SHIP_ENDPOINT      = local.input["METRICS_SHIP_ENDPOINT"]
    TRACES_SHIP_ENDPOINT       = local.input["TRACES_SHIP_ENDPOINT"]
    SHIP_TRUSTED_CAS           = local.input["SHIP_TRUSTED_CAS"]
    SHIP_AUTHORIZATION         = local.input["SHIP_AUTHORIZATION"]
    CERT_ALERT_DAYS            = local.input["CERT_ALERT_DAYS"]

    # Realm people's client (keycloak/configure.sh); a session idle as long as realm people's ends.
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET              = random_password.this["grafana-client"].result
    GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION = "${local.input["CONSOLE_IDLE_MINUTES"]}m"
  })
  lifecycle {
    precondition {
      # Grafana refuses to start on an address without a domain dot (e.g. user@localhost).
      condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$", local.input["GF_SMTP_FROM_ADDRESS"]))
      error_message = "GF_SMTP_FROM_ADDRESS: an email address whose domain has a dot, e.g. heeyid-alerts@example.com."
    }
    precondition {
      condition = (local.input["LOG_SHIP_PROTOCOL"] == "off" && local.input["LOG_SHIP_ENDPOINT"] == "") || (
        local.input["LOG_SHIP_PROTOCOL"] == "otlp" && can(regex("^https://[^/:]+:[0-9]+(/.*)?$", local.input["LOG_SHIP_ENDPOINT"]))) || (
      local.input["LOG_SHIP_PROTOCOL"] == "syslog" && can(regex("^[^/:]+:[0-9]+$", local.input["LOG_SHIP_ENDPOINT"])))
      error_message = "LOG_SHIP_PROTOCOL, LOG_SHIP_ENDPOINT: otlp with https://<host>:<port>/<path>, syslog with <host>:<port>, or off with no endpoint."
    }
    precondition {
      condition     = alltrue([for k in ["METRICS_SHIP_ENDPOINT", "TRACES_SHIP_ENDPOINT"] : local.input[k] == "" || can(regex("^https://[^/:]+:[0-9]+(/.*)?$", local.input[k]))])
      error_message = "METRICS_SHIP_ENDPOINT, TRACES_SHIP_ENDPOINT: https://<host>:<port>/<path>, the bank's OTLP/HTTP URL for that kind, or empty to keep it on the host."
    }
    precondition {
      condition     = local.shipping ? strcontains(local.input["SHIP_TRUSTED_CAS"], "BEGIN CERTIFICATE") : local.input["SHIP_TRUSTED_CAS"] == "" && local.input["SHIP_AUTHORIZATION"] == ""
      error_message = "SHIP_TRUSTED_CAS: the PEM of the CA that signed the bank's collectors' certificates when anything is shipped; with nothing shipped, it and SHIP_AUTHORIZATION stay empty."
    }
    precondition {
      condition     = local.input["SHIP_AUTHORIZATION"] == "" || local.input["LOG_SHIP_PROTOCOL"] == "otlp" || local.input["METRICS_SHIP_ENDPOINT"] != "" || local.input["TRACES_SHIP_ENDPOINT"] != ""
      error_message = "SHIP_AUTHORIZATION: sent only to OTLP collectors; with none of them it stays empty."
    }
    precondition {
      condition     = can(regex("^([1-9]|1[0-9]|2[0-9])$", local.input["CERT_ALERT_DAYS"]))
      error_message = "CERT_ALERT_DAYS: 1 to 29 days before a certificate's end to alert (apply renews heeyID's own in their last 30)."
    }
  }
}

# Each tenant's MyID credential as the adapter's config file (myid.tenants): a one-shot writes it to a
# volume only the adapter reads (docker-compose.yml, myid-tenants).
resource "vault_kv_secret_v2" "myid_tenants" {
  mount = vault_mount.secret.path
  name  = "env/myid-tenants"
  data_json = jsonencode({
    MYID_TENANTS_YAML = local.myid_tenants_yaml
  })
  lifecycle {
    precondition {
      condition     = length(local.myid_tenants) > 0
      error_message = "secret/myid-tenants has no tenant: scripts/install.sh add-tenant (the adapter does not start without one)."
    }
    precondition {
      condition = alltrue([for name, t in local.myid_tenants :
        can(regex("^[a-z][a-z0-9-]{0,62}$", name)) && t["client-id"] != "" && t["client-secret"] != ""
      && (t["username"] == "") == (t["password"] == "")])
      error_message = "secret/myid-tenants: each name lowercase letters, digits and -, with its client-id and client-secret, and username and password both or neither; scripts/install.sh add-tenant checks them."
    }
  }
}

resource "vault_kv_secret_v2" "myid_adapter" {
  mount = vault_mount.secret.path
  name  = "env/myid-adapter"
  data_json = jsonencode(merge(local.otlp, {
    MYID_ADAPTER_PORT            = "8093"
    MYID_ADAPTER_MANAGEMENT_PORT = "8193"
    MYID_ADAPTER_SSL_CERTIFICATE = vault_pki_secret_backend_cert.this["myid-adapter"].certificate
    MYID_ADAPTER_SSL_PRIVATE_KEY = vault_pki_secret_backend_cert.this["myid-adapter"].private_key
    MYID_ADAPTER_SSL_TRUSTED_CAS = vault_pki_secret_backend_cert.this["myid-adapter"].issuing_ca
    MYID_ADAPTER_ISSUER_URI      = local.issuer
    MYID_ADAPTER_AUDIENCE        = "myid-adapter"
    MYID_ADAPTER_TENANTS_FILE    = "/run/myid-tenants/myid-tenants.yaml" # docker-compose.yml, myid-tenants
    MYID_BASE_URL                = local.input["MYID_BASE_URL"]
    MYID_MEDIA_URL               = local.input["MYID_MEDIA_URL"]
    # SAD TB-5: MyID over TLS with a pinned CA, and its tokens in Valkey only encrypted.
    MYID_TRUSTED_CAS       = local.input["MYID_TRUSTED_CAS"]
    MYID_ADAPTER_TOKEN_KEY = random_bytes.myid_token_key.base64
    # MyID answers each call in 5 s, an Inplace or compare result in 30 s (docs.myid.uz).
    MYID_CONNECT_TIMEOUT = "2s"
    MYID_READ_TIMEOUT    = "35s"
    # SAD §8: the breaker opens after 5 failures in a row and probes each 30 s.
    MYID_BREAKER_FAILURES    = "5"
    MYID_BREAKER_PROBE_AFTER = "30s"
    VALKEY_HOST              = "valkey"
    VALKEY_PORT              = "6379"
    VALKEY_USERNAME          = "myid-adapter"
    VALKEY_PASSWORD          = random_password.this["valkey-myid-adapter"].result
  }))
  lifecycle {
    precondition {
      condition     = alltrue([for k in ["MYID_BASE_URL", "MYID_MEDIA_URL"] : can(regex("^https://[a-z0-9.-]+(:[0-9]+)?$", local.input[k]))])
      error_message = "MYID_BASE_URL, MYID_MEDIA_URL: https://<host>[:<port>], MyID's hosts for this zone, no path."
    }
  }
}
