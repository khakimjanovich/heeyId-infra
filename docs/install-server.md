# heeyID: install

## 1. Before you start

- A Linux host (4 vCPU, 8 GB RAM, 100 GB SSD) with Docker and the Compose v2 plugin (not 2.32.0), `git`, `jq`, `openssl`, `curl`.
- A login to `ghcr.io` that reads `khakimjanovich/myid-adapter`, `khakimjanovich/sms-adapter` and `khakimjanovich/taf-adapter` (`docker login ghcr.io`, a token with `read:packages`).
- The five keyholders of Vault's unseal shares, each with a password manager.
- From the bank: an address for the consoles' door and a DNS record `*.<CONSOLES_DOMAIN>` to it; the directory (LDAPS) with its CA, a read-only account and the consoles' two groups; a mail relay; MyID's hosts for this zone and heeyID's one MyID credential (client id and secret, and the login for the Backend API without personal data); SMS Xabar's login (username and password), the sender name the bank registered at Xabar, and the addresses Xabar sends delivery reports from; TAF's hosts for this zone (token endpoint, agent, agent's health), their CA, and heeyID's one TAF credential (client id, secret and scope); an address on this host for the delivery reports' door, the addresses of the bank's ingress, and a public URL on that ingress that passes `/delivery-reports/` to the door (plain HTTP, port 8080, with `X-Forwarded-For`); and, if the bank wants heeyID's logs, metrics or traces, its collectors, their CA and their `Authorization` header.

Every value: [settings.md](settings.md). None has a default: a missing one stops the install, by name.

## 2. Install

```bash
git clone https://github.com/khakimjanovich/heeyId-infra.git && cd heeyId-infra
scripts/install.sh
```

Seven waves ([vault.md](vault.md), "Installer waves"); each proves its part, prints how to get in, and waits for `ok`. A stop goes on from the same wave when run again.

### Xabar's delivery reports

After wave 7, give Xabar the partner URL `https://<the ingress's public name>/delivery-reports/xabar/<secret>` (Xabar adds `/status`). The secret, with a root token: `v kv get -field=XABAR_CALLBACK_SECRET secret/env/sms-adapter`. Send it to Xabar by a protected channel. Ask Xabar for its status words and for any callback authentication: its document lists neither.

## 3. Backups and restore

The install and every `apply` leave a Vault snapshot and the OpenTofu state in `~/backups`: copy them to the bank's backup storage. Restore: `v operator raft snapshot restore <file>` on a new Vault, unseal with the old shares. Valkey holds only tokens MyID gives again and the SMS adapter's keys and statuses, kept 7 days, and the token TAF gives again; Postgres holds Keycloak's realms (`pg_dump` it with the bank's database backups).

## 4. Upgrade and rollback

Change `HEEYID_VERSION` in `.env.local`, then `VAULT_TOKEN=$(render_token 1h) scripts/stack.sh deploy`. Rollback: the earlier version, the same command.

## 5. After a reboot

`scripts/install.sh`: it unseals Vault (three keyholders) and starts what is needed. Health any time: `scripts/install.sh check`.

## 6. Rotations

| What | How |
|---|---|
| a service's or a console's certificate | `apply` renews it in its last 30 days; the certificate watch alerts `CERT_ALERT_DAYS` before the end |
| a generated password or secret | `apply -replace=…` ([vault.md](vault.md)) |
| Keycloak's signing keys | `KEYCLOAK_KEY_ROTATE_DAYS`, by keycloak-config at each start |
| the MyID credential | `v kv patch secret/input/heeyid MYID_CLIENT_SECRET=…` (or another `MYID_` key), then `apply` ([settings.md](settings.md)) |
| the Xabar login | `v kv patch secret/input/heeyid XABAR_PASSWORD=…` (or `XABAR_USERNAME`), then `apply` |
| the TAF credential | `v kv patch secret/input/heeyid TAF_CLIENT_SECRET=…` (or another `TAF_` key), then `apply` |
| the Xabar callback secret | `apply -replace=random_password.xabar_callback_secret`, then give Xabar the new partner URL |

## 7. Troubleshooting

`scripts/stack.sh ps`, `scripts/stack.sh logs <service>`; Grafana, heeyID · availability and heeyID · logs. The adapters' own problem lines carry the outcome's code (`MYID_ADAPTER_…`, `SMS_ADAPTER_…`, `TAF_ADAPTER_…`) and the vendor's answer.
