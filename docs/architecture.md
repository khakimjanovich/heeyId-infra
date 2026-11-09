# Architecture

heeyID on one host with Docker Compose: two projects, `heeyid-vault` (Vault alone, started first) and `heeyid` (everything else). Design: SAD MVP 1 §6 (deployment), §7.2 (key custody), §8 (the MyID adapter).

For now it runs what the MyID adapter needs, with its stores, sign-in and observability. The gateways, the workers, Kafka and their databases come with them; the realm `services` and the CA already name the adapter's two callers, `customer-gateway` and `workers`.

## What runs

| Service | What | Reached by |
|---|---|---|
| `vault` (`heeyid-vault`) | settings and secrets, heeyID's CA | the consoles' door (`vault.<CONSOLES_DOMAIN>`), the installer |
| `postgres`, `postgres-init` | Keycloak's database | Keycloak |
| `valkey` | each tenant's MyID tokens (keys `t:<tenant>:myid-adapter:*`, encrypted), one ACL user per service, append-only file each second | the MyID adapter (user `myid-adapter`) |
| `heeyid-keycloak`, `keycloak-config` | realm `services` (services' tokens), realm `people` (the consoles' people, from the bank's directory) | services at `https://heeyid-keycloak:8443`, people through the consoles' door |
| `observability` | Grafana, Loki, Prometheus, Tempo, the collector; alerts by mail | Grafana through the consoles' door |
| `mailpit` (when `MAILPIT=on`) | catches the alert mails | the consoles' door |
| `heeyid-consoles` | the consoles' one door, `CONSOLES_ADDRESS:443`, by TLS SNI | operators |
| `myid-tenants` | one-shot: writes each tenant's MyID credential to the volume only the adapter reads | — |
| `myid-adapter` | `myid-adapter-api` over mutual TLS: every MyID flow | heeyID's services at `https://myid-adapter:8093` |

## The MyID adapter

- **Callers:** a client certificate from heeyID's CA (role `callers`) and a token of realm `services` with the audience `myid-adapter` and the role `myid.use`. `customer-gateway` and `workers` hold both in `keycloak/services-realm.json`; their client secrets are in `secret/env/keycloak-config`.
- **MyID:** `MYID_BASE_URL` and `MYID_MEDIA_URL`, the zone's hosts, over HTTPS. Each tenant's credential from `secret/myid-tenants`. Timeouts 2 s to connect, 35 s to read (MyID answers a result in up to 30 s). The breaker opens after 5 failures in a row and probes each 30 s (SAD §8).
- **Tokens:** in Valkey, shared by every instance, until 5 minutes before MyID's expiry.
- **Health:** `/actuator/health` on port 8193 (plain HTTP, inside the network), Valkey included.

## Networks

| Network | Who |
|---|---|
| `heeyid_default` | every service |
| `heeyid_consoles` | the consoles' door and the consoles (Keycloak, Grafana, Mailpit) |
| `heeyid-vault` | Vault and the consoles' door |

Nothing publishes a port but the consoles' door. The MyID adapter reaches MyID through the host's route out (the bank's egress proxy permits MyID, SAD §6).

## Start order

`scripts/stack.sh up`: Vault up and unsealed, its certificate renewed, every setting rendered from Vault to `.env.vault/`, the images pulled, then Compose with each service waiting for what it needs (`depends_on`): Postgres → Keycloak → keycloak-config; Valkey, observability and myid-tenants → myid-adapter.

## Observability

Every service sends its logs, metrics and traces (OTLP) to `observability`; the collector also reads every container's log file and Vault's audit file. Everything stays in this stack; each kind also goes to the bank's collector when its setting names one ([settings.md](settings.md), "The bank's observability").

Grafana, folder `heeyid`:

- **heeyID · availability:** the MyID adapter up, MyID answering, the MyID breaker, calls to MyID by outcome, MyID's answer time, requests into the adapter, health components DOWN, warnings and errors.
- **heeyID · logs:** every line of the MyID adapter, by level and text.
- **Alerts** ([`rules.yaml`](../observability/alerting/rules.yaml)), mailed to `ALERT_EMAILS`: MyID unavailable, MyID breaker open, MyID refuses the adapter (a client error, or a tenant's credential), dependency unavailable, HTTP 5xx above 1%, health DOWN, service sends no metrics, certificate ends soon, certificate watch stopped.

## A service from source (bootRun)

`VAULT_TOKEN=$(render_token 1h) scripts/stack.sh render host` writes `.env.vault/host.env` with the MyID adapter's settings and `secret/env/host` (what differs on a developer's host). Its tenants file: `jq -r .MYID_TENANTS_YAML .env.vault/myid-tenants.json`.
