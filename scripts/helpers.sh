unalias v t root render_token apply env_local_value vapi 2> /dev/null || true

v() {
  local tty=-T; [ -t 0 ] && [ -t 1 ] && tty=
  docker compose --env-file .env.local -f vault/docker-compose.yml exec $tty -e VAULT_ADDR=https://127.0.0.1:8200 \
    -e VAULT_CACERT=/vault/ca/ca.pem -e VAULT_TOKEN vault vault "$@"
}

env_local_value() { [ -f .env.local ] && sed -n "s/^$1=//p" .env.local | head -n 1; }

vapi() {
  docker compose --env-file .env.local -f vault/docker-compose.yml exec -T vault \
    wget -q -O - --no-check-certificate --post-file /dev/stdin "https://127.0.0.1:8200/v1/$1" 2> /dev/null
}

t() {
  local tty= domain; [ -t 0 ] && [ -t 1 ] && tty=-t
  domain=$(env_local_value CONSOLES_DOMAIN)
  [ -n "$domain" ] || { echo "CONSOLES_DOMAIN is missing from .env.local (docs/settings.md, \"Settings\")" >&2; return 1; }
  docker run --rm -i $tty --network heeyid-vault -e VAULT_ADDR=https://vault:8200 -e VAULT_CACERT=/vault-ca/ca.pem \
    -e VAULT_TOKEN -e TF_VAR_state_passphrase -e TF_VAR_consoles_domain="$domain" -v heeyid_vault-ca:/vault-ca:ro \
    -v "$PWD/vault:/vault-config" -w /vault-config/tofu ghcr.io/opentofu/opentofu:1.10.6 "$@"
}

root() {
  local attempt nonce otp result share
  v operator generate-root -cancel < /dev/null > /dev/null 2>&1
  attempt=$(printf '{}' | vapi sys/generate-root/attempt)
  nonce=$(printf '%s' "$attempt" | jq -r '.nonce // empty'); otp=$(printf '%s' "$attempt" | jq -r '.otp // empty')
  [ -n "$nonce" ] || { echo "Vault didn't start a root-token attempt: is it unsealed and running?" >&2; return 1; }
  while :; do
    printf 'Unseal share: ' > /dev/tty; stty -echo < /dev/tty; IFS= read -r share < /dev/tty; stty echo < /dev/tty; printf '\n' > /dev/tty
    result=$(KEY=$share NONCE=$nonce jq -n '{key: env.KEY, nonce: env.NONCE}' | vapi sys/generate-root/update)
    [ "$(printf '%s' "$result" | jq -r '.complete // empty')" = true ] && break
    [ -n "$result" ] || { echo "Vault refused that share, or didn't answer"; continue; }
    printf '%s' "$result" | jq -r '"progress \(.progress) of \(.required)"'
  done
  VAULT_TOKEN=$(printf '%s' "$result" | jq -r .encoded_token | v operator generate-root -decode=- -otp="$otp"); export VAULT_TOKEN
  v token lookup | grep policies
}

render_token() {
  v token create -orphan -policy=env-read -policy=vault-tls-read -policy=cert-watch -ttl="${1:?render_token <ttl>, e.g. 1h}" -field=token < /dev/null
}

apply() {
  local token status
  t apply "$@" || return
  token=$(render_token 15m) || return
  VAULT_TOKEN=$token scripts/stack.sh up && status=0 || status=$?
  (VAULT_TOKEN=$token; export VAULT_TOKEN; v token revoke -self < /dev/null > /dev/null)
  return $status
}
