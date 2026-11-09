# heeyID: install

## 1. Before you start

- A Linux host (4 vCPU, 8 GB RAM, 100 GB SSD) with Docker and the Compose v2 plugin (not 2.32.0), `git`, `jq`, `openssl`, `curl`.
- A login to `ghcr.io` that reads `khakimjanovich/myid-adapter` (`docker login ghcr.io`, a token with `read:packages`).
- The five keyholders of Vault's unseal shares, each with a password manager.
- From the bank: an address for the consoles' door and a DNS record `*.<CONSOLES_DOMAIN>` to it; the directory (LDAPS) with its CA, a read-only account and the consoles' two groups; a mail relay; MyID's hosts for this zone and each tenant's MyID credential (client id and secret, and the login for the Backend API without personal data when the contract has it); and, if the bank wants heeyID's logs, metrics or traces, its collectors, their CA and their `Authorization` header.

Every value: [settings.md](settings.md). None has a default: a missing one stops the install, by name.

## 2. Install

```bash
git clone https://github.com/khakimjanovich/heeyId-infra.git && cd heeyId-infra
scripts/install.sh
```

Seven waves ([vault.md](vault.md), "Installer waves"); each proves its part, prints how to get in, and waits for `ok`. A stop goes on from the same wave when run again.

## 3. Tenants

```bash
scripts/install.sh add-tenant           # asks for the tenant's name and MyID credential
scripts/install.sh remove-tenant <name>
```

Each asks for a root token (or makes one from three keyholders' shares) and the state passphrase, writes `secret/myid-tenants`, runs `apply` (the MyID adapter restarts with the new list), checks the stack, backs up and revokes the token.

## 4. Backups and restore

The install and every tenant change leave a Vault snapshot and the OpenTofu state in `~/backups`: copy them to the bank's backup storage. Restore: `v operator raft snapshot restore <file>` on a new Vault, unseal with the old shares. Valkey holds only tokens MyID gives again; Postgres holds Keycloak's realms (`pg_dump` it with the bank's database backups).

## 5. Upgrade and rollback

Change `HEEYID_VERSION` in `.env.local`, then `VAULT_TOKEN=$(render_token 1h) scripts/stack.sh deploy`. Rollback: the earlier version, the same command.

## 6. After a reboot

`scripts/install.sh`: it unseals Vault (three keyholders) and starts what is needed. Health any time: `scripts/install.sh check`.

## 7. Rotations

| What | How |
|---|---|
| a service's or a console's certificate | `apply` renews it in its last 30 days; the certificate watch alerts `CERT_ALERT_DAYS` before the end |
| a generated password or secret | `apply -replace=…` ([vault.md](vault.md)) |
| Keycloak's signing keys | `KEYCLOAK_KEY_ROTATE_DAYS`, by keycloak-config at each start |
| a tenant's MyID credential | `scripts/install.sh add-tenant` with the same name |

## 8. Troubleshooting

`scripts/stack.sh ps`, `scripts/stack.sh logs <service>`; Grafana, heeyID · availability and heeyID · logs. The MyID adapter's own problem lines carry the outcome's code (`MYID_ADAPTER_…`) and MyID's answer.
