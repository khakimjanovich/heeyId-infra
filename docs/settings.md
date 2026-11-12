# Settings

Every service's settings are at `secret/env/<service>`, written by `t apply` ([`settings.tf`](../vault/tofu/settings.tf)) and generated where possible: passwords, client secrets and keys once, certificates from heeyID's CA. You supply only what the environment alone knows, at `secret/input/heeyid`. A missing key stops `t apply` and names it. No setting has a default.

Change a value, with a root token ([vault.md](vault.md)): `v kv patch secret/input/heeyid KEY=value`, then `apply`.

`.env.local` holds what Compose itself needs (marked `.env.local` below); everything else is in Vault.

<!-- inputs: scripts/install.sh docs writes this table from scripts/inputs.json -->
| Key | What | Example (⏎: Enter takes it) |
|---|---|---|
| `HEEYID_VERSION` (`.env.local`) | the release to run: the images' tag, the git tag without the `v` (`local`: an image built on this host from heeyid, for a test stand) | `1.0.0` |
| `CONSOLES_ADDRESS` (`.env.local`) | the address of the consoles' one door (heeyid-consoles, port 443): the host's address on the network the operators reach it from (the bank's jump host), never 0.0.0.0. It must stay fixed: a static address, or a DHCP reservation; the consoles' names (CONSOLES_DOMAIN) resolve to it | `192.0.2.20` |
| `CONSOLES_DOMAIN` (`.env.local`) | the domain the consoles are named under: vault., keycloak., grafana. and mailpit. + it, each through the door on CONSOLES_ADDRESS, each certificate naming its name. The platform maps the names to CONSOLES_ADDRESS: the bank's DNS (one record, *.<domain>), or /etc/hosts on a lone machine | `consoles.example.com` |
| `CALLBACKS_ADDRESS` (`.env.local`) | the address of the door for the SMS vendors' delivery reports (heeyid-callbacks, port 8080, plain HTTP): the host's address on the network the bank's ingress reaches it from, never 0.0.0.0. The ingress ends TLS for the public URL and passes only `/delivery-reports/` here; it must stay fixed | `192.0.2.21` |
| `LOG_MAX_SIZE` (`.env.local`) | a container's log file size before Docker rotates it (`k` or `m`); the collector ships each line as it is written, so rotation loses nothing | `100m` ⏎ |
| `LOG_MAX_FILES` (`.env.local`) | how many rotated log files Docker keeps per container | `5` ⏎ |
| `VAULT_AUDIT_MAX_MB` (`.env.local`) | the size in MB at which Vault's audit file is rotated (Vault reopens it, no line lost) | `100` ⏎ |
| `VAULT_AUDIT_KEEP` (`.env.local`) | how many rotated audit files stay on Vault's volume; the bank's SIEM keeps the year | `10` ⏎ |
| `MAILPIT` | `on` runs the mail catcher for heeyID's alerts (`mailpit:1025`, inbox https://mailpit.<CONSOLES_DOMAIN>); `off` runs none (its image is never pulled) | `off` |
| `PULL_ATTEMPTS` | how many times `up` and `deploy` try to pull the images before giving up | `3` ⏎ |
| `PULL_RETRY_SECONDS` | the seconds between two pull tries | `30` ⏎ |
| `GF_SMTP_HOST` | Grafana's mail relay, `host:port` | `smtp.example.com:587` |
| `GF_SMTP_USER` | the relay's login; empty without one | `heeyid-alerts` |
| `GF_SMTP_PASSWORD` 🔒 | the relay's password; empty without one | `relay-password` |
| `GF_SMTP_STARTTLS_POLICY` | `NoStartTLS` with Mailpit, `MandatoryStartTLS` with a real relay | `MandatoryStartTLS` |
| `GF_SMTP_FROM_ADDRESS` | the alerts' sender: an address whose domain has a dot (Grafana refuses one without) | `heeyid-alerts@example.com` |
| `ALERT_EMAILS` | where alerts go, `;`-separated | `oncall@example.com;security@example.com` |
| `MYID_BASE_URL` | MyID's host for this zone (`{myid_host}` in MyID's documentation): its test environment on stage, its production service in production (SAD §6, zone separation). `https://<host>`, no path | `https://myid-host.example.uz` |
| `MYID_MEDIA_URL` | MyID's media host for this zone (`{myid_media_host}`, the Inplace photo upload), from the same contract as MYID_BASE_URL | `https://myid-media-host.example.uz` |
| `MYID_TRUSTED_CAS` | the CA that signed MyID's certificates for this zone (PEM; the installer asks for the file). The adapter trusts MyID only through it (SAD TB-5, pinned CA) | `~/tls/myid-ca.pem` |
| `MYID_CLIENT_ID` | heeyID's MyID client_id, from the bank's contract with MyID for this zone (one per installation, SAD C-13) | `bank-client-id` |
| `MYID_CLIENT_SECRET` 🔒 | that client's client_secret | `client-secret` |
| `MYID_USERNAME` | the MyID login for the Backend API without personal data (photo comparison, the password grant), from the same contract | `bank-login` |
| `MYID_PASSWORD` 🔒 | that login's password | `login-password` |
| `XABAR_USERNAME` | heeyID's login at SMS Xabar (Play Mobile SMS-Broker API, Basic auth), from the bank's contract with Xabar | `bank-login` |
| `XABAR_PASSWORD` 🔒 | that login's password | `xabar-password` |
| `XABAR_ORIGINATOR` | the sender name the bank registered at Xabar: what the customer sees as the sender | `BANK` |
| `XABAR_ADDRESSES` | the addresses Xabar sends its delivery reports from (ask Xabar): IPv4 addresses or networks, comma separated. heeyid-callbacks takes a report only for one of them, as the bank's ingress names it in X-Forwarded-For | `203.0.113.10,203.0.113.11` |
| `CALLBACKS_INGRESS_ADDRESSES` | the addresses the bank's ingress connects to CALLBACKS_ADDRESS from: IPv4 addresses or networks, comma separated. heeyid-callbacks takes no connection from anywhere else, and trusts X-Forwarded-For only from these | `192.0.2.5` |
| `TAF_AUTH_URL` | TAF's (Telecom AntiFraud) OAuth 2.0 token endpoint for this zone, the full URL, from the bank's contract with TAF | `https://taf-auth.example.uz/oauth2/token` |
| `TAF_AGENT_URL` | the TAF agent in the bank's network (its API host) for this zone: `https://<host>[:<port>]` | `https://taf-agent.example.uz` |
| `TAF_HEALTH_URL` | the TAF agent's health, the full URL (the agent's host, port 8081, `/actuator/health`) | `https://taf-agent.example.uz:8081/actuator/health` |
| `TAF_TRUSTED_CAS` | the CA that signed TAF's certificates for this zone (PEM; the installer asks for the file). The adapter trusts TAF only through it (SAD TB-5, pinned CA) | `~/tls/taf-ca.pem` |
| `TAF_CLIENT_ID` | heeyID's TAF client_id (client_credentials), from the bank's contract with TAF for this zone, one per installation | `bank-client-id` |
| `TAF_CLIENT_SECRET` 🔒 | that client's client_secret | `client-secret` |
| `TAF_SCOPE` | the scope TAF gives that client (the token request's `scope`), from the same contract | `taf-scope` |
| `FCM_PROJECT_ID` | the bank's Firebase project for this zone (its project ID, as Firebase's console shows it): the push adapter sends through it only | `bank-heeyid-prod` |
| `FCM_SERVICE_ACCOUNT` 🔒 | the JSON key of that project's service account with role `roles/firebasecloudmessaging.admin` (the installer asks for the file; docs/install-server.md, "The FCM credential"). Only the push adapter gets it, as a file | `~/tls/fcm-service-account.json` |
| `LDAP_URL` | the bank's directory (Active Directory or another LDAP server) the consoles' people sign in with, over TLS only: `ldaps://<host>[:<port>]`. Keycloak reads people and their two groups from it, never writes; their passwords stay there | `ldaps://dc.example.com:636` |
| `LDAP_TRUSTED_CAS` | the CA that signed the directory's certificate (PEM; the installer asks for the file) | `~/tls/directory-ca.pem` |
| `LDAP_VENDOR` | `ad` for Active Directory, `other` for another LDAP server (OpenLDAP, 389 Directory Server, …) | `ad` |
| `LDAP_BIND_DN` | the directory account Keycloak reads with: read-only on the people and the two groups, nothing else | CN=heeyid-keycloak,OU=Service Accounts,DC=example,DC=com |
| `LDAP_BIND_PASSWORD` 🔒 | that account's password | `bind-password` |
| `LDAP_USERS_DN` | where the people are, searched with everything below it | `OU=People,DC=example,DC=com` |
| `LDAP_USER_OBJECT_CLASSES` | the object classes of a person, comma-separated: `person, organizationalPerson, user` in Active Directory, `inetOrgPerson, organizationalPerson` in OpenLDAP | person, organizationalPerson, user |
| `LDAP_USERNAME_ATTRIBUTE` | the attribute people sign in with: `sAMAccountName` in Active Directory, `uid` in OpenLDAP | `sAMAccountName` |
| `LDAP_UUID_ATTRIBUTE` | the attribute that names a person for ever, even renamed: `objectGUID` in Active Directory, `entryUUID` in OpenLDAP | `objectGUID` |
| `LDAP_ADMINS_GROUP_DN` | the directory group of the consoles' admins: Grafana's Admin role and Keycloak's admin console. Its direct members count (not those of a group nested in it); a DN with an escaped character (`\`) isn't taken; the directory must give people the `memberOf` attribute (Active Directory always does; OpenLDAP with its memberof overlay) | `CN=heeyid-console-admins,OU=Groups,DC=example,DC=com` |
| `LDAP_VIEWERS_GROUP_DN` | the directory group of the consoles' viewers: Grafana's Viewer role. Someone in neither group can't sign in to any console; removed from a group in the directory, they lose it at their next sign-in | `CN=heeyid-console-viewers,OU=Groups,DC=example,DC=com` |
| `CONSOLE_LOCKOUT_FAILURES` | failed sign-ins in a row before an account is locked, 10 at most | `10` ⏎ |
| `CONSOLE_LOCKOUT_MINUTES` | how long a locked account stays locked, 30 minutes or more | `30` ⏎ |
| `CONSOLE_IDLE_MINUTES` | idle minutes before a console session ends, 15 at most | `15` ⏎ |
| `KEYCLOAK_KEY_ROTATE_DAYS` | the token signing keys' cryptoperiod in days, 365 at most: keycloak-config makes a new key this often in every realm and retires the old one a period later | `180` ⏎ |
| `LOG_SHIP_PROTOCOL` | how every log line also goes to the bank's observability, when the bank gives a collector: `otlp` (OTLP/HTTP over TLS) or `syslog` (RFC 5424 over TCP with TLS); `off` keeps them in this stack only (they always stay here too) | `off` |
| `LOG_SHIP_ENDPOINT` | the bank's log collector: `https://<host>:<port>/<path>` (the full OTLP logs URL) for otlp, `<host>:<port>` for syslog; observability checks it answers when it starts. Empty with `off` | `siem.example.com:6514` |
| `METRICS_SHIP_ENDPOINT` | the bank's OTLP/HTTP metrics URL, `https://<host>:<port>/<path>` in full (e.g. …/v1/metrics), when the bank gives one; observability checks it answers when it starts. Empty: the metrics stay in this stack only | `https://otel.example.com:4318/v1/metrics` |
| `TRACES_SHIP_ENDPOINT` | the bank's OTLP/HTTP traces URL, `https://<host>:<port>/<path>` in full (e.g. …/v1/traces), when the bank gives one. Empty: the traces stay in this stack only | `https://otel.example.com:4318/v1/traces` |
| `SHIP_TRUSTED_CAS` | the CA that signed the bank's collectors' certificates (PEM; the installer asks for the file). Empty when nothing is shipped | `~/tls/bank-observability-ca.pem` |
| `SHIP_AUTHORIZATION` 🔒 | the `Authorization` header the bank's OTLP collectors want, as it is sent (e.g. `Bearer <token>` or `Basic <base64>`); not sent to syslog. Empty when they want none | Bearer &lt;token> |
| `CERT_ALERT_DAYS` | days before a certificate's end that Grafana alerts, daily until it is renewed: the services', the consoles', the CAs, the callers' client certificates. Below 30: `apply` renews heeyID's own certificates in their last 30 days, so a longer lead would alert on ones it hasn't renewed yet | `21` ⏎ |
<!-- /inputs -->

## Database and cache users

Generated by `t apply`, never asked for. The gateways and the workers get them when they come.

| Key | Where | What |
|---|---|---|
| `HEEYID_DB_<MODULE>_PASSWORD` 🔒 | `secret/env/postgres` | one Postgres user for each module (`ACCESS`, `CUSTOMER`, `GRANTS`, `ANTIFRAUD`, `NOTIFICATION`, `CATALOGUE`, `STAFF`, `AUDIT`): the user has the module's name, owns the schema of that name in database `heeyid`, runs the module's migrations there, and has no right in any other schema |
| `HEEYID_DB_VIEWER_PASSWORD` 🔒 | `secret/env/postgres` | Postgres user `heeyid_viewer`: SELECT on every module's tables, nothing else |
| `HEEYID_DB_<MODULE>_URL`, `_USERNAME`, `_PASSWORD`, `_POOL_SIZE` | `secret/env/customer-gw-db`, `admin-gw-db`, `workers-db` | each app's settings `heeyid.db.<module>.*` for each module it loads, with that module's Hikari pool size (README, "Postgres connections") |
| `VALKEY_CUSTOMER_GW_PASSWORD` 🔒 | `secret/env/valkey` | Valkey user `customer-gw`, keys `customer-gw:*` |
| `VALKEY_ADMIN_GW_PASSWORD` 🔒 | `secret/env/valkey` | Valkey user `admin-gw`, keys `admin-gw:*` |
| `VALKEY_WORKERS_PASSWORD` 🔒 | `secret/env/valkey` | Valkey user `workers`, keys `workers:*` |

`postgres-init` and `valkey` do not start without them, and name the missing one.

## The bank's observability

heeyID keeps its own logs, metrics and traces in its `observability` stack (Grafana, Loki, Prometheus, Tempo) in every case. When the bank gives collectors, each kind also goes there:

| Kind | Setting | Empty or `off` |
|---|---|---|
| every log line (the apps', every container's, Vault's audit) | `LOG_SHIP_PROTOCOL` `otlp` or `syslog`, `LOG_SHIP_ENDPOINT` | stays here only |
| metrics | `METRICS_SHIP_ENDPOINT` (OTLP/HTTP) | stays here only |
| traces | `TRACES_SHIP_ENDPOINT` (OTLP/HTTP) | stays here only |

All of them over TLS, checked against `SHIP_TRUSTED_CAS`; `SHIP_AUTHORIZATION` is sent as the `Authorization` header to the OTLP ones when the bank wants one. `observability` checks each collector answers when it starts, and does not start when one doesn't. A queue on disk rides out an outage of a collector.
