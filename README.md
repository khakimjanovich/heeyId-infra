# heeyid-infra

Runs heeyID on one Linux host with Docker Compose, the same way `cards-infra` and `ecom-infra` run theirs. This repo builds nothing; it pulls the images built from [heeyid](https://github.com/khakimjanovich/heeyid) at `HEEYID_VERSION`.

For now: the MyID adapter (`ghcr.io/khakimjanovich/myid-adapter`) with what it needs, Vault (settings, secrets, heeyID's CA), Valkey (the MyID adapter's tokens), Keycloak (realm `services` for the services' tokens, realm `people` for the consoles), Postgres (Keycloak's database), and observability: heeyID's own Grafana, Loki, Prometheus and Tempo, and, when the bank gives collectors, its logs, metrics and traces there too. The customer gateway, the admin gateway, the workers, Kafka and the administrator panel come with their images.

Design: SAD MVP 1 §6 (deployment view), §7.2 (key custody), §8 (integration adapters), constraints C-1, C-4, C-10, C-15.

Rule: every input has no default. A missing value stops the install or the start with a clear error.

## Run

```bash
scripts/install.sh                       # first install: seven waves, asks for what it needs
scripts/install.sh check
scripts/stack.sh up                      # start an installed stack
```

## Docs

| | |
|---|---|
| [docs/install-server.md](docs/install-server.md) | Install, backups, upgrade, reboot, rotations |
| [docs/settings.md](docs/settings.md) | Every input with an example (generated from `scripts/inputs.json`), the bank's observability |
| [docs/vault.md](docs/vault.md) | The Vault ceremony, helpers, installer waves |
| [docs/architecture.md](docs/architecture.md) | What runs, the MyID adapter, networks, start order, observability |
