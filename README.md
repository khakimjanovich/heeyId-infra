# heeyid-infra

Runs heeyID on one Linux host with Docker Compose, the same way `cards-infra` and `ecom-infra` run theirs. This repo builds nothing; it pulls the images built from [heeyid](https://github.com/khakimjanovich/heeyid) at `HEEYID_VERSION`.

For now: the MyID adapter (`ghcr.io/khakimjanovich/myid-adapter`) and the SMS adapter (`ghcr.io/khakimjanovich/sms-adapter`, SMS Xabar, with its delivery reports' door `heeyid-callbacks`) and the TAF adapter (`ghcr.io/khakimjanovich/taf-adapter`, Telecom AntiFraud) and the push adapter (`ghcr.io/khakimjanovich/push-adapter`, Firebase Cloud Messaging) with what they need, Vault (settings, secrets, heeyID's CA), Valkey (the MyID adapter's tokens, the SMS adapter's keys and statuses, the TAF adapter's token), Keycloak (realm `services` for the services' tokens, realm `people` for the consoles), Postgres (Keycloak's database, and `heeyid` with one schema and one user for each module), and observability: heeyID's own Grafana, Loki, Prometheus and Tempo, and, when the bank gives collectors, its logs, metrics and traces there too. The customer gateway, the admin gateway, the workers, Kafka and the administrator panel come with their images.

Design: SAD MVP 1 §6 (deployment view), §7.2 (key custody), §8 (integration adapters), constraints C-1, C-4, C-10, C-15.

Rule: every input has no default. A missing value stops the install or the start with a clear error.

## Run

```bash
scripts/install.sh                       # first install: seven waves, asks for what it needs
scripts/install.sh check
scripts/stack.sh up                      # start an installed stack
```

## Postgres connections

`max_connections` is 200. Each module has its own Hikari pool in each app that loads it (`secret/env/<app>-db`, `vault/tofu/settings.tf`); Keycloak's pool is `KC_DB_POOL_MAX_SIZE`.

| Pool | access | customer | grants | antifraud | notification | catalogue | staff | audit | Sum |
|---|---|---|---|---|---|---|---|---|---|
| customer-gw | 8 | 8 | 10 | 4 | 3 | 2 | | | 35 |
| admin-gw | | 3 | 2 | 1 | 2 | 2 | 3 | | 13 |
| workers | 2 | 2 | 2 | 2 | 3 | 1 | 1 | 3 | 16 |
| Keycloak | | | | | | | | | 30 |

One customer-gw: 35 + 13 + 16 + 30 = 94 of 200. Two customer-gw: 129 of 200, 71 left for the superuser's 3 reserved, `postgres-init`, a break-glass `psql` and `heeyid_viewer`. Add a pool or an instance only with this count.

`audit_user` owns schema `audit`, so the database alone does not stop it from changing `audit_event`: the audit module's migration adds the trigger that refuses UPDATE and DELETE there.

## Docs

| | |
|---|---|
| [docs/install-server.md](docs/install-server.md) | Install, backups, upgrade, reboot, rotations |
| [docs/settings.md](docs/settings.md) | Every input with an example (generated from `scripts/inputs.json`), the bank's observability |
| [docs/vault.md](docs/vault.md) | The Vault ceremony, helpers, installer waves |
| [docs/architecture.md](docs/architecture.md) | What runs, the MyID, SMS, TAF and push adapters, networks, start order, observability |
