# Vault

[`hashicorp/vault:1.20.4`](https://hub.docker.com/r/hashicorp/vault), run by `vault/docker-compose.yml` with [`vault/vault.hcl`](../vault/vault.hcl): Raft storage on volume `vault-data`, listener on 8200, TLS only. Reached as `https://vault.<CONSOLES_DOMAIN>` through `heeyid-consoles`; no published port.

- **Certificate:** from heeyID's CA (`secret/tls/vault`). `scripts/stack.sh` writes it to volume `vault-tls` and reloads Vault with SIGHUP, so renewal never seals it. On a new install, before the CA exists, it makes a 30-day self-signed one.
- **Trust:** on the host `.env.vault/vault-ca.pem`; in containers volume `vault-ca`.
- **At runtime** no service reads Vault yet: every setting is rendered before a service starts (`.env.vault/`, never committed).
- **Setup as code:** [`vault/tofu`](../vault/tofu) with [OpenTofu](https://opentofu.org/docs/) (audit log, policies, the CA, every service's settings). Opening Vault (init, unseal, root token) is manual. The repo holds no key, token or value.

## What you keep

In a password manager, never in the repo or a chat:

| What | For |
|---|---|
| Unseal key shares, one per keyholder (5, 3 to unseal) | opening Vault after every start; making a root token |
| State passphrase | decrypting OpenTofu's state, which holds every generated secret |

Every generated password is read back when needed: `v kv get -field=KC_BOOTSTRAP_ADMIN_PASSWORD secret/env/keycloak`.

## Helpers

```bash
. scripts/helpers.sh    # each new terminal, from the clone's root
```

| | |
|---|---|
| `v …` | `vault` CLI inside the container |
| `t …` | OpenTofu from its image on Vault's network |
| `root` | makes a root token from the keyholders' shares |
| `apply` | `t apply`, then `scripts/stack.sh up` with a 15-minute settings-only token it makes and revokes; compose recreates only the services whose settings changed |
| `render_token 1h` | a settings-only token (`env-read`, `vault-tls-read`, `cert-watch`) |

A change in Vault reaches the services only through `apply`.

## Root token

For any change by hand (`t apply`, a patched value): `root`, each keyholder types a share (unseen); it ends with `policies [root]`. When done:

```bash
v token revoke -self
```

`t plan` shows drift: a hand change in Vault, or a certificate in its last 30 days (`apply` renews it and restarts what uses it). Rotate a generated value: `apply -replace='random_password.this["valkey-myid-adapter"]'`.

## Installer waves

`scripts/install.sh` runs seven waves. Each starts only its services, proves real access, prints how to get in, waits for `ok`. `.install/progress` records confirmed waves (no secrets); a rerun continues at the first unconfirmed one.

| Wave | Does | Proves |
|---|---|---|
| 1 Host | checks Docker, Compose (not 2.32.0), `jq`, `openssl`, `curl`; asks for `.env.local`; ports free; images readable | the same |
| 2 Vault | inits Vault (5 shares, 3 to unseal), shows shares and root token once until each keyholder pastes theirs back, unseals, asks the state passphrase, every setting ([settings.md](settings.md)), the MyID credential among them, writes `secret/input/heeyid`, `tofu apply`, renders settings, pulls images | consoles' door up; `vault.<CONSOLES_DOMAIN>` serves heeyID's certificate; a settings-only token reads `secret/env/stack` and is refused `secret/input/heeyid` |
| 3 Postgres | `postgres`, `postgres-init` | user `keycloak` signs in to its database |
| 4 Valkey | `valkey` | user `myid-adapter` writes its own keys only; nobody gets in without a sign-in |
| 5 Keycloak | `heeyid-keycloak`, `keycloak-config` | `customer-gateway` gets a token for `myid-adapter` with role `myid.use`; realm `people` sign-in answers with heeyID's certificate |
| 6 Grafana | `observability` (and `mailpit` when on) | sign-in redirects to realm `people`; Prometheus, Loki, Tempo answer |
| 7 MyID adapter | `myid-adapter` | healthy, metrics in Grafana |

After the waves: whole stack once more, health check, Vault snapshot and OpenTofu state in `~/backups`, root token revoked, `.install/access.txt` written (URLs and groups, no secrets).

**Answers file** for a repeat install: `scripts/install.sh --answers <file>` (mode 600), one `KEY=value` per input of [settings.md](settings.md), a PEM as `KEY=@<path>`. Never shares, tokens or the passphrase.

## Deploy a new version

```bash
VAULT_TOKEN=<render_token 1h> scripts/stack.sh deploy
```

`deploy` is `up` with images pulled again, then it removes finished one-shot containers and images the stack no longer uses. Data volumes are never touched. Change `HEEYID_VERSION` first for a new version. Pin release tags: a moving tag like `main` cannot tell old from new. `up` alone removes nothing.

## Clean start

⚠️ Deletes heeyID's data, Vault's included. The only way back if too few unseal shares remain.

```bash
docker compose -p heeyid down -v
docker compose -p heeyid-vault down -v
rm -f vault/tofu/terraform.tfstate vault/tofu/terraform.tfstate.backup
rm -rf .install
```
