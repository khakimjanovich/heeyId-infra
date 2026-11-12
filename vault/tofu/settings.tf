# Every service's settings, secret/env/<service>, which scripts/stack.sh renders before anything
# starts. Three kinds of value:
#   - this stack's own: addresses, ports, timeouts, the same in every environment (locals);
#   - generated here and written to both sides that must agree: passwords, client secrets, each
#     service's certificate (renewed by apply in its last 30 days);
#   - the environment's: what only its operator knows (MyID's hosts, the bank's collectors, mail, the
#     directory, Xabar's login and addresses, TAF's hosts and credential, the FCM project and its
#     service account), read from secret/input/heeyid, which scripts/install.sh
#     writes (docs/settings.md, "Settings"), the MyID credential among them. A key missing there stops plan.
# Rotating a generated value: `tofu apply -replace=<resource>`, then deploy.

data "vault_kv_secret_v2" "input" {
  mount = vault_mount.secret.path
  name  = "input/heeyid"
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
  services        = toset(["myid-adapter", "sms-adapter", "taf-adapter", "push-adapter"])
  internal_domain = "heeyid.internal"
  # The adapters' callers: heeyID's own clients in realm services (keycloak/services-realm.json), each
  # with the roles and audiences of the adapters it calls. Their deployables come later; their
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
  # An IPv4 address or network, as heeyid-callbacks takes them.
  address = "[0-9]{1,3}([.][0-9]{1,3}){3}(/[0-9]{1,2})?"
  # The ship settings: an empty endpoint ships nothing of that kind.
  shipping = local.input["LOG_SHIP_PROTOCOL"] != "off" || local.input["METRICS_SHIP_ENDPOINT"] != "" || local.input["TRACES_SHIP_ENDPOINT"] != ""
  # The modules: in database heeyid one schema and one user <module>_user each (postgres/init.sql), in
  # Kafka one user <module>_user each (kafka/init.sh). db_pools: the modules each app loads, with each
  # one's Hikari pool size; an app loads a module when it serves it or calls it in-process. An app gets
  # the database and Kafka settings of the modules it loads only.
  db_modules = ["access", "customer", "grants", "antifraud", "notification", "catalogue", "staff", "audit"]
  db_pools = {
    "customer-gw" = { access = 8, customer = 8, grants = 10, antifraud = 4, notification = 3, catalogue = 2 }
    "admin-gw"    = { customer = 3, staff = 3, grants = 2, notification = 2, antifraud = 1, catalogue = 2 }
    "workers"     = { access = 2, customer = 2, grants = 2, antifraud = 2, notification = 3, catalogue = 1, staff = 1, audit = 3 }
  }
}

resource "random_password" "this" {
  for_each = toset(["postgres", "keycloak-db", "keycloak-admin", "grafana-admin", "keycloak-config-client", "grafana-client", "valkey-myid-adapter", "valkey-sms-adapter", "valkey-taf-adapter", "valkey-customer-gw", "valkey-admin-gw", "valkey-workers"])
  length   = 32
  special  = false # values go into env files and JDBC URLs unquoted
}

# The module users of database heeyid, and heeyid_viewer (SELECT only).
resource "random_password" "db" {
  for_each = toset(concat(local.db_modules, ["viewer"]))
  length   = 32
  special  = false
}

# The AES-256 key of the MyID tokens in Valkey (SAD TB-5: cached in Valkey only encrypted).
resource "random_bytes" "myid_token_key" {
  length = 32
}

# The AES-256 key of the TAF token in Valkey (SAD TB-5, the same rule).
resource "random_bytes" "taf_token_key" {
  length = 32
}

# The secret in the partner URL given to Xabar (/delivery-reports/xabar/<secret>/status): URL-safe,
# 32 to 128 characters (the adapter's rule).
resource "random_password" "xabar_callback_secret" {
  length  = 48
  special = false
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

# Postgres: Keycloak's database, and the gateways' database heeyid with its users (postgres/init.sql).
resource "vault_kv_secret_v2" "postgres" {
  mount = vault_mount.secret.path
  name  = "env/postgres"
  data_json = jsonencode(merge(
    { for u in keys(random_password.db) : "HEEYID_DB_${upper(u)}_PASSWORD" => random_password.db[u].result },
    {
      POSTGRES_PASSWORD    = random_password.this["postgres"].result
      KEYCLOAK_DB_PASSWORD = random_password.this["keycloak-db"].result
  }))
}

# Each app's connection to database heeyid: for each module it loads, the module's own user and its own
# Hikari pool (heeyid.db.<module>.*). secret/env/<app>-db, rendered together with the app's other
# settings when the app comes. The sum of every pool, Keycloak's included, stays under Postgres'
# max_connections (README, "Postgres connections").
resource "vault_kv_secret_v2" "db" {
  for_each = local.db_pools
  mount    = vault_mount.secret.path
  name     = "env/${each.key}-db"
  data_json = jsonencode(merge([for m, size in each.value : {
    "HEEYID_DB_${upper(m)}_URL"       = "jdbc:postgresql://postgres:5432/heeyid"
    "HEEYID_DB_${upper(m)}_USERNAME"  = "${m}_user"
    "HEEYID_DB_${upper(m)}_PASSWORD"  = random_password.db[m].result
    "HEEYID_DB_${upper(m)}_POOL_SIZE" = tostring(size)
  }]...))
}

# Valkey: the default user is off; each service has its own ACL user for its own keys
# (valkey/start.sh). Keys start with the service's name (SAD §6, "Cache").
resource "vault_kv_secret_v2" "valkey" {
  mount = vault_mount.secret.path
  name  = "env/valkey"
  data_json = jsonencode({
    VALKEY_MYID_ADAPTER_PASSWORD = random_password.this["valkey-myid-adapter"].result
    VALKEY_SMS_ADAPTER_PASSWORD  = random_password.this["valkey-sms-adapter"].result
    VALKEY_TAF_ADAPTER_PASSWORD  = random_password.this["valkey-taf-adapter"].result
    VALKEY_CUSTOMER_GW_PASSWORD  = random_password.this["valkey-customer-gw"].result
    VALKEY_ADMIN_GW_PASSWORD     = random_password.this["valkey-admin-gw"].result
    VALKEY_WORKERS_PASSWORD      = random_password.this["valkey-workers"].result
  })
}

resource "random_password" "kafka" {
  for_each = toset(concat(["admin"], local.db_modules))
  length   = 32
  special  = false # values go into properties files unquoted
}

# Kafka: user admin (PLAIN) for the node and kafka-init, and one SCRAM user <module>_user per module,
# which writes only its topic <module>.events and audit; inside heeyID only audit_user reads audit
# (kafka/init.sh).
resource "vault_kv_secret_v2" "kafka" {
  mount     = vault_mount.secret.path
  name      = "env/kafka"
  data_json = jsonencode({ for u, p in random_password.kafka : "KAFKA_${upper(u)}_PASSWORD" => p.result })
}

# Each app's Kafka settings, secret/env/<app>-kafka: one user for each module it loads (local.db_pools).
resource "vault_kv_secret_v2" "kafka_app" {
  for_each = { for app, pools in local.db_pools : app => keys(pools) }
  mount    = vault_mount.secret.path
  name     = "env/${each.key}-kafka"
  data_json = jsonencode(merge(
    {
      HEEYID_KAFKA_BOOTSTRAP_SERVERS = "kafka:9092"
      HEEYID_KAFKA_SECURITY_PROTOCOL = "SASL_PLAINTEXT"
      HEEYID_KAFKA_SASL_MECHANISM    = "SCRAM-SHA-512"
      HEEYID_KAFKA_AUDIT_TOPIC       = "audit"
    },
    { for m in each.value : "HEEYID_KAFKA_${upper(m)}_USERNAME" => "${m}_user" },
    { for m in each.value : "HEEYID_KAFKA_${upper(m)}_PASSWORD" => random_password.kafka[m].result },
    { for m in each.value : "HEEYID_KAFKA_${upper(m)}_TOPIC" => "${m}.events" if m != "audit" },
    contains(each.value, "audit") ? { HEEYID_KAFKA_AUDIT_GROUP = "audit" } : {},
  ))
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
    MYID_BASE_URL                = local.input["MYID_BASE_URL"]
    MYID_MEDIA_URL               = local.input["MYID_MEDIA_URL"]
    # The adapter's MyID credential, one per installation (SAD C-13).
    MYID_CLIENT_ID     = local.input["MYID_CLIENT_ID"]
    MYID_CLIENT_SECRET = local.input["MYID_CLIENT_SECRET"]
    MYID_USERNAME      = local.input["MYID_USERNAME"]
    MYID_PASSWORD      = local.input["MYID_PASSWORD"]
    # SAD TB-5: MyID over TLS with a pinned CA, and its tokens in Valkey only encrypted.
    MYID_TRUSTED_CAS       = local.input["MYID_TRUSTED_CAS"]
    MYID_ADAPTER_TOKEN_KEY = random_bytes.myid_token_key.base64
    # MyID answers each call in 5 s; /users/me, the Inplace job result and the compare results in 30 s
    # (docs.myid.uz).
    MYID_CONNECT_TIMEOUT   = "2s"
    MYID_READ_TIMEOUT      = "7s"
    MYID_LONG_READ_TIMEOUT = "35s"
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

resource "vault_kv_secret_v2" "sms_adapter" {
  mount = vault_mount.secret.path
  name  = "env/sms-adapter"
  data_json = jsonencode(merge(local.otlp, {
    SMS_ADAPTER_PORT            = "8094"
    SMS_ADAPTER_MANAGEMENT_PORT = "8194"
    # Xabar's delivery reports, plain HTTP, only from heeyid-callbacks (the bank's ingress behind it).
    SMS_ADAPTER_CALLBACK_PORT   = "8294"
    SMS_ADAPTER_SSL_CERTIFICATE = vault_pki_secret_backend_cert.this["sms-adapter"].certificate
    SMS_ADAPTER_SSL_PRIVATE_KEY = vault_pki_secret_backend_cert.this["sms-adapter"].private_key
    SMS_ADAPTER_SSL_TRUSTED_CAS = vault_pki_secret_backend_cert.this["sms-adapter"].issuing_ca
    SMS_ADAPTER_ISSUER_URI      = local.issuer
    SMS_ADAPTER_AUDIENCE        = "sms-adapter"
    SMS_ACTIVE_VENDOR           = "xabar"
    SMS_FAILOVER_VENDORS        = "" # none yet
    SMS_MESSAGE_ID_PREFIX       = "hid"
    SMS_RETENTION               = "7d"
    # SAD §8: each vendor's breaker opens after 5 failures in a row and probes each 30 s.
    SMS_BREAKER_FAILURES    = "5"
    SMS_BREAKER_PROBE_AFTER = "30s"
    XABAR_BASE_URL          = "https://send.smsxabar.uz/broker-api"
    XABAR_CONNECT_TIMEOUT   = "2s"
    XABAR_READ_TIMEOUT      = "10s"
    XABAR_USERNAME          = local.input["XABAR_USERNAME"]
    XABAR_PASSWORD          = local.input["XABAR_PASSWORD"]
    XABAR_ORIGINATOR        = local.input["XABAR_ORIGINATOR"]
    XABAR_CALLBACK_SECRET   = random_password.xabar_callback_secret.result
    VALKEY_HOST             = "valkey"
    VALKEY_PORT             = "6379"
    VALKEY_USERNAME         = "sms-adapter"
    VALKEY_PASSWORD         = random_password.this["valkey-sms-adapter"].result
  }))
}

# heeyid-callbacks (callbacks/start.sh): the door of Xabar's delivery reports. It takes a connection
# only from the bank's ingress, and a request only for an address of Xabar's, as the ingress names it
# in X-Forwarded-For.
resource "vault_kv_secret_v2" "callbacks" {
  mount = vault_mount.secret.path
  name  = "env/callbacks"
  data_json = jsonencode({
    CALLBACKS_INGRESS_ADDRESSES = local.input["CALLBACKS_INGRESS_ADDRESSES"]
    XABAR_ADDRESSES             = local.input["XABAR_ADDRESSES"]
  })
  lifecycle {
    precondition {
      condition     = alltrue([for k in ["CALLBACKS_INGRESS_ADDRESSES", "XABAR_ADDRESSES"] : can(regex("^${local.address}(,${local.address})*$", local.input[k]))])
      error_message = "CALLBACKS_INGRESS_ADDRESSES, XABAR_ADDRESSES: IPv4 addresses or networks (a.b.c.d or a.b.c.d/n), comma separated, no spaces."
    }
  }
}

resource "vault_kv_secret_v2" "taf_adapter" {
  mount = vault_mount.secret.path
  name  = "env/taf-adapter"
  data_json = jsonencode(merge(local.otlp, {
    TAF_ADAPTER_PORT            = "8095"
    TAF_ADAPTER_MANAGEMENT_PORT = "8195"
    TAF_ADAPTER_SSL_CERTIFICATE = vault_pki_secret_backend_cert.this["taf-adapter"].certificate
    TAF_ADAPTER_SSL_PRIVATE_KEY = vault_pki_secret_backend_cert.this["taf-adapter"].private_key
    TAF_ADAPTER_SSL_TRUSTED_CAS = vault_pki_secret_backend_cert.this["taf-adapter"].issuing_ca
    TAF_ADAPTER_ISSUER_URI      = local.issuer
    TAF_ADAPTER_AUDIENCE        = "taf-adapter"
    TAF_AUTH_URL                = local.input["TAF_AUTH_URL"]
    TAF_AGENT_URL               = local.input["TAF_AGENT_URL"]
    TAF_HEALTH_URL              = local.input["TAF_HEALTH_URL"]
    # The adapter's TAF credential, one per installation (client_credentials).
    TAF_CLIENT_ID     = local.input["TAF_CLIENT_ID"]
    TAF_CLIENT_SECRET = local.input["TAF_CLIENT_SECRET"]
    TAF_SCOPE         = local.input["TAF_SCOPE"]
    # SAD TB-5: TAF over TLS with a pinned CA, and its token in Valkey only encrypted.
    TAF_TRUSTED_CAS       = local.input["TAF_TRUSTED_CAS"]
    TAF_ADAPTER_TOKEN_KEY = random_bytes.taf_token_key.base64
    # SAD C-15: 5 s for each TAF call; the breaker opens after 5 failures in a row and probes each 30 s.
    TAF_CONNECT_TIMEOUT     = "2s"
    TAF_READ_TIMEOUT        = "5s"
    TAF_BREAKER_FAILURES    = "5"
    TAF_BREAKER_PROBE_AFTER = "30s"
    VALKEY_HOST             = "valkey"
    VALKEY_PORT             = "6379"
    VALKEY_USERNAME         = "taf-adapter"
    VALKEY_PASSWORD         = random_password.this["valkey-taf-adapter"].result
  }))
  lifecycle {
    precondition {
      condition     = alltrue([for k in ["TAF_AUTH_URL", "TAF_AGENT_URL", "TAF_HEALTH_URL"] : can(regex("^https://[a-z0-9.-]+(:[0-9]+)?(/[^ ]*)?$", local.input[k]))])
      error_message = "TAF_AUTH_URL, TAF_AGENT_URL, TAF_HEALTH_URL: https://<host>[:<port>][/<path>], TAF's hosts for this zone (the adapter trusts them only through TAF_TRUSTED_CAS)."
    }
    precondition {
      condition     = strcontains(local.input["TAF_TRUSTED_CAS"], "BEGIN CERTIFICATE")
      error_message = "TAF_TRUSTED_CAS: the PEM of the CA that signed TAF's certificates for this zone."
    }
  }
}

# The push adapter keeps no state (no Valkey user). Its FCM credential is the bank's service-account
# JSON key for this zone's Firebase project: here only base64 (one line in the env file); push/start.sh
# writes it to FCM_CREDENTIALS_FILE on the container's memory volume (mode 0400) and drops the variable
# before the adapter starts.
resource "vault_kv_secret_v2" "push_adapter" {
  mount = vault_mount.secret.path
  name  = "env/push-adapter"
  data_json = jsonencode(merge(local.otlp, {
    PUSH_ADAPTER_PORT            = "8096"
    PUSH_ADAPTER_MANAGEMENT_PORT = "8196"
    PUSH_ADAPTER_SSL_CERTIFICATE = vault_pki_secret_backend_cert.this["push-adapter"].certificate
    PUSH_ADAPTER_SSL_PRIVATE_KEY = vault_pki_secret_backend_cert.this["push-adapter"].private_key
    PUSH_ADAPTER_SSL_TRUSTED_CAS = vault_pki_secret_backend_cert.this["push-adapter"].issuing_ca
    PUSH_ADAPTER_ISSUER_URI      = local.issuer
    PUSH_ADAPTER_AUDIENCE        = "push-adapter"
    FCM_PROJECT_ID               = local.input["FCM_PROJECT_ID"]
    FCM_CREDENTIALS_FILE         = "/run/fcm/service-account.json"
    FCM_CREDENTIALS_JSON_BASE64  = base64encode(local.input["FCM_SERVICE_ACCOUNT"])
    # SAD C-15: 5 s for the whole send, the SDK's retries included; SAD §8: the breaker opens after 5
    # failures in a row and probes each 30 s.
    FCM_CONNECT_TIMEOUT      = "2s"
    FCM_READ_TIMEOUT         = "5s"
    FCM_SEND_TIMEOUT         = "5s"
    PUSH_BREAKER_FAILURES    = "5"
    PUSH_BREAKER_PROBE_AFTER = "30s"
  }))
  lifecycle {
    precondition {
      condition     = try(jsondecode(local.input["FCM_SERVICE_ACCOUNT"]).type == "service_account", false)
      error_message = "FCM_SERVICE_ACCOUNT: the JSON key of a Google service account (type service_account)."
    }
    precondition {
      condition     = try(jsondecode(local.input["FCM_SERVICE_ACCOUNT"]).project_id == local.input["FCM_PROJECT_ID"], false)
      error_message = "FCM_SERVICE_ACCOUNT: its project_id is not FCM_PROJECT_ID; the key must be from this zone's Firebase project."
    }
  }
}
