# Architecture

heeyID on one host with Docker Compose: two projects, `heeyid-vault` (Vault alone, started first) and `heeyid` (everything else). Design: SAD MVP 1 §6 (deployment), §7.2 (key custody), §8 (the MyID, SMS, TAF and push adapters), ADR-36 (the push adapter).

For now it runs the MyID, SMS, TAF and push adapters, with their stores, sign-in and observability. The gateways, the workers, Kafka and their databases come with them; the realm `services` and the CA already name the adapters' callers, `customer-gateway` and `workers`.

## What runs

| Service | What | Reached by |
|---|---|---|
| `vault` (`heeyid-vault`) | settings and secrets, heeyID's CA | the consoles' door (`vault.<CONSOLES_DOMAIN>`), the installer |
| `postgres`, `postgres-init` | Keycloak's database; database `heeyid` with one schema and one user for each module | Keycloak; the gateways and the workers when they come |
| `valkey` | the MyID adapter's tokens (keys `myid-adapter:*`, encrypted); the SMS adapter's idempotency keys and message statuses (keys `sms-adapter:key:*`, `sms-adapter:message:*`, no text and no phone number); the TAF adapter's token (key `taf-adapter:token`, encrypted); one ACL user per service, append-only file each second | the MyID adapter (user `myid-adapter`), the SMS adapter (user `sms-adapter`), the TAF adapter (user `taf-adapter`) |
| `heeyid-keycloak`, `keycloak-config` | realm `services` (services' tokens), realm `people` (the consoles' people, from the bank's directory) | services at `https://heeyid-keycloak:8443`, people through the consoles' door |
| `observability` | Grafana, Loki, Prometheus, Tempo, the collector; alerts by mail | Grafana through the consoles' door |
| `mailpit` (when `MAILPIT=on`) | catches the alert mails | the consoles' door |
| `heeyid-consoles` | the consoles' one door, `CONSOLES_ADDRESS:443`, by TLS SNI | operators |
| `myid-adapter` | `myid-adapter-api` over mutual TLS: every MyID flow | heeyID's services at `https://myid-adapter:8093` |
| `sms-adapter` | `sms-adapter-api` over mutual TLS: one-time codes and security notices through SMS Xabar | heeyID's services at `https://sms-adapter:8094`; Xabar's delivery reports through `heeyid-callbacks` |
| `taf-adapter` | `taf-adapter-api` over mutual TLS: one-time codes through TAF (Telecom AntiFraud) | heeyID's services at `https://taf-adapter:8095` |
| `push-adapter` | `push-adapter-api` over mutual TLS: push messages through FCM HTTP v1 (type and reference only, no text) | heeyID's workers at `https://push-adapter:8096` |
| `heeyid-callbacks` | the door of the SMS vendors' delivery reports, `CALLBACKS_ADDRESS:8080`, plain HTTP | the bank's ingress only, for Xabar's addresses |

## The MyID adapter

- **Callers:** a client certificate from heeyID's CA (role `callers`) and a token of realm `services` with the audience `myid-adapter` and the role `myid.use`. `customer-gateway` and `workers` hold both in `keycloak/services-realm.json`; their client secrets are in `secret/env/keycloak-config`.
- **MyID:** `MYID_BASE_URL` and `MYID_MEDIA_URL`, the zone's hosts, over HTTPS. Its one credential (SAD C-13) from `secret/input/heeyid` (`MYID_CLIENT_ID`, `MYID_CLIENT_SECRET`, `MYID_USERNAME`, `MYID_PASSWORD`). Timeouts 2 s to connect, 35 s to read (MyID answers a result in up to 30 s). The breaker opens after 5 failures in a row and probes each 30 s (SAD §8).
- **Tokens:** in Valkey, shared by every instance, until 5 minutes before MyID's expiry.
- **Health:** `/actuator/health` on port 8193 (plain HTTP, inside the network), Valkey included.

## The SMS adapter

- **Callers:** a client certificate from heeyID's CA (role `callers`) and a token of realm `services` with the audience `sms-adapter` and the role `sms.use`. `customer-gateway` holds both in `keycloak/services-realm.json`.
- **Xabar:** `XABAR_BASE_URL` (`https://send.smsxabar.uz/broker-api`), the login `XABAR_USERNAME` and `XABAR_PASSWORD` and the sender name `XABAR_ORIGINATOR` from `secret/input/heeyid`. Timeouts 2 s to connect, 10 s to read. Vendors: `SMS_ACTIVE_VENDOR=xabar`, no failover yet (`SMS_FAILOVER_VENDORS` empty). Each vendor's breaker opens after 5 failures in a row and probes each 30 s (SAD §8).
- **Keys:** in Valkey, kept `SMS_RETENTION` (7 days): idempotency keys and message statuses, shared by every instance.
- **Delivery reports:** Xabar posts to `https://<the bank's ingress>/delivery-reports/xabar/<XABAR_CALLBACK_SECRET>/status`. The ingress ends TLS and passes the request to `heeyid-callbacks` on `CALLBACKS_ADDRESS:8080`. The door takes a connection only from `CALLBACKS_INGRESS_ADDRESSES`, a request only when the last address in `X-Forwarded-For` is in `XABAR_ADDRESSES`, and only `POST` on that path; it passes it to the adapter's callback port 8294 on the network `heeyid_callbacks`. The adapter checks the secret (OpenTofu makes it, 48 characters). The door logs no secret.
- **Ports:** 8094 the API (mutual TLS), 8194 health (`/actuator/health`, plain HTTP, inside the network, Valkey included), 8294 the delivery reports (plain HTTP, `heeyid_callbacks` only).

## The TAF adapter

- **Callers:** a client certificate from heeyID's CA (role `callers`) and a token of realm `services` with the audience `taf-adapter` and the role `taf.use`. `customer-gateway` holds both in `keycloak/services-realm.json`.
- **TAF:** `TAF_AUTH_URL`, `TAF_AGENT_URL`, `TAF_HEALTH_URL`, the credential `TAF_CLIENT_ID`, `TAF_CLIENT_SECRET`, `TAF_SCOPE` and TAF's CA `TAF_TRUSTED_CAS` (pinned, SAD TB-5), all from `secret/input/heeyid`. Timeouts 2 s to connect, 5 s to read (SAD C-15). The breaker opens after 5 failures in a row and probes each 30 s; its `/v1/health` is DOWN then, and the gateway sends codes through the bank's SMS.
- **Token:** in Valkey (key `taf-adapter:token`), encrypted with `TAF_ADAPTER_TOKEN_KEY` (AES-256, generated by OpenTofu), shared by every instance.
- **Ports:** 8095 the API (mutual TLS), 8195 health (`/actuator/health`, plain HTTP, inside the network, Valkey included).

## The push adapter

- **Callers:** a client certificate from heeyID's CA (role `callers`) and a token of realm `services` with the audience `push-adapter` and the role `push.use`. `workers` holds both in `keycloak/services-realm.json`.
- **FCM:** the bank's Firebase project for this zone, `FCM_PROJECT_ID`, and its service account's JSON key, `FCM_SERVICE_ACCOUNT`, both from `secret/input/heeyid` ([install-server.md](install-server.md), "The FCM credential"). OpenTofu puts the key in `secret/env/push-adapter` as base64 only after it checks that it is a service account of `FCM_PROJECT_ID`. At each start [`push/start.sh`](../push/start.sh) writes it to `FCM_CREDENTIALS_FILE` (`/run/fcm/service-account.json`) on a memory volume (tmpfs, mode 0700, the adapter's user only), file mode 0400, and removes the variable before the JVM starts. The key is never on the container's disk.
- **Timeouts:** 2 s to connect, 5 s to read, 5 s for the whole send with the SDK's own retries (SAD C-15). The breaker opens after 5 failures in a row and probes each 30 s (SAD §8).
- **State:** none. No Valkey user, no database.
- **Ports:** 8096 the API (mutual TLS), 8196 health (`/actuator/health`, plain HTTP, inside the network).
- **Egress:** `fcm.googleapis.com:443` (FCM HTTP v1) and `oauth2.googleapis.com:443` (the service account's tokens). Only the push adapter calls them.

## Networks

| Network | Who |
|---|---|
| `heeyid_default` | every service |
| `heeyid_consoles` | the consoles' door and the consoles (Keycloak, Grafana, Mailpit) |
| `heeyid-vault` | Vault and the consoles' door |
| `heeyid_callbacks` | the delivery reports' door and the SMS adapter |

Only two doors publish a port: the consoles' door (`CONSOLES_ADDRESS:443`) and the delivery reports' door (`CALLBACKS_ADDRESS:8080`). The adapters reach MyID, Xabar, the TAF agent and FCM through the host's route out (the bank's egress proxy permits them, SAD §6). This repo runs no egress proxy of its own; the bank's proxy must permit `fcm.googleapis.com` and `oauth2.googleapis.com` (port 443) for this host. If the bank's route out is an explicit HTTP proxy, give the push adapter `JAVA_TOOL_OPTIONS=-Dhttps.proxyHost=<host> -Dhttps.proxyPort=<port>` (its SDK uses the JVM's proxy).

## Start order

`scripts/stack.sh up`: Vault up and unsealed, its certificate renewed, every setting rendered from Vault to `.env.vault/`, the images pulled, then Compose with each service waiting for what it needs (`depends_on`): Postgres → Keycloak → keycloak-config; Valkey and observability → myid-adapter, sms-adapter, taf-adapter; observability → push-adapter.

## Observability

Every service sends its logs, metrics and traces (OTLP) to `observability`; the collector also reads every container's log file and Vault's audit file. Everything stays in this stack; each kind also goes to the bank's collector when its setting names one ([settings.md](settings.md), "The bank's observability").

Grafana, folder `heeyid`:

- **heeyID · availability:** the MyID adapter up, MyID answering, the MyID breaker, the SMS adapter up, the SMS vendors' breakers, the TAF adapter up, the TAF breaker, the push adapter up, the FCM breaker, calls to MyID by outcome, MyID's answer time, requests into the MyID adapter, health components DOWN, warnings and errors.
- **heeyID · logs:** every line of the MyID, SMS, TAF and push adapters, by level and text.
- **Alerts** ([`rules.yaml`](../observability/alerting/rules.yaml)), mailed to `ALERT_EMAILS`: MyID unavailable, MyID breaker open, MyID refuses the adapter (a client error, or the adapter's credential), SMS vendor breaker open, TAF breaker open, FCM breaker open, dependency unavailable, HTTP 5xx above 1%, health DOWN, service sends no metrics, certificate ends soon, certificate watch stopped.

## A service from source (bootRun)

`VAULT_TOKEN=$(render_token 1h) scripts/stack.sh render host` writes `.env.vault/host.env` with the MyID adapter's settings and `secret/env/host` (what differs on a developer's host).
