#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

DOCKER_ROOT_DIR=$(docker info --format '{{.DockerRootDir}}'); export DOCKER_ROOT_DIR
. scripts/helpers.sh # env_local_value: .env.local's one reader
compose() { docker compose --env-file .env.local "$@"; }
pull=missing # what pull_images fetches. up: an image this host doesn't have yet; deploy: always
vault_compose() { docker compose --env-file .env.local -f vault/docker-compose.yml "$@"; }
vault_status() { vault_compose exec -T vault vault status -address=https://127.0.0.1:8200 -ca-cert=/vault/ca/ca.pem -format=json 2> /dev/null; }

vault_tls_write() {
  tar -C "$1" -cf - server.pem server-key.pem ca.pem \
    | vault_compose run --rm -T --no-deps -u root --entrypoint /bin/sh vault -c 'set -e; tar -xf - -C /tmp
      mv /tmp/server.pem /tmp/server-key.pem /vault/tls/; mv /tmp/ca.pem /vault/ca/
      chown vault /vault/tls/server.pem /vault/tls/server-key.pem; chmod 600 /vault/tls/server-key.pem
      chmod 644 /vault/tls/server.pem /vault/ca/ca.pem' > /dev/null
  mkdir -p .env.vault
  cp "$1/ca.pem" .env.vault/vault-ca.pem
}

vault_tls_bootstrap() {
  mkdir -p .env.vault
  if ca=$(vault_compose run --rm -T --no-deps --entrypoint cat vault /vault/ca/ca.pem 2> /dev/null) && [ -n "$ca" ]; then
    printf '%s\n' "$ca" > .env.vault/vault-ca.pem
    return
  fi
  dir=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=vault \
    -addext 'subjectAltName=DNS:vault,IP:127.0.0.1' \
    -keyout "$dir/server-key.pem" -out "$dir/server.pem" 2> /dev/null
  cp "$dir/server.pem" "$dir/ca.pem"
  vault_tls_write "$dir"
  rm -rf "$dir"
  echo "Vault: a self-signed certificate for now; heeyID's CA issues its own (t apply, then up)"
}

vault_tls_renew() {
  : "${VAULT_TOKEN:?VAULT_TOKEN is required}"
  tls=$(vault_compose exec -T -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_CACERT=/vault/ca/ca.pem -e VAULT_TOKEN vault \
    vault kv get -format=json secret/tls/vault 2> /dev/null) \
    || { echo "secret/tls/vault can't be read: OpenTofu hasn't issued Vault's certificate yet (t apply with a root token), or the token lacks policy vault-tls-read (helpers' apply makes one with it)" >&2; exit 1; }
  [ "$(vault_compose exec -T vault cat /vault/tls/server.pem)" = "$(printf '%s' "$tls" | jq -r .data.data.VAULT_TLS_CERTIFICATE)" ] && return
  dir=$(mktemp -d)
  printf '%s' "$tls" | jq -r .data.data.VAULT_TLS_CERTIFICATE > "$dir/server.pem"
  printf '%s' "$tls" | jq -r .data.data.VAULT_TLS_PRIVATE_KEY > "$dir/server-key.pem"
  printf '%s' "$tls" | jq -r .data.data.VAULT_TLS_CA > "$dir/ca.pem"
  vault_tls_write "$dir"
  rm -rf "$dir"
  vault_compose kill -s HUP vault > /dev/null 2>&1
  echo "Vault: serving its certificate from heeyID's CA"
}

vault_up() {
  vault_tls_bootstrap
  vault_compose up -d
  tries=0
  until [ -n "$(vault_status || true)" ]; do
    tries=$((tries + 1)); [ "$tries" -lt 60 ] || { echo "Vault did not answer in 60 s" >&2; exit 1; }
    sleep 1
  done
}

vault_ready() {
  status=$(vault_status || true)
  printf '%s' "$status" | jq -e .initialized > /dev/null \
    || { echo "Vault is not initialised: set it up first (docs/vault.md, \"Vault\")" >&2; exit 1; }
  printf '%s' "$status" | jq -e '.sealed | not' > /dev/null \
    || { echo "Vault is sealed: unseal it first (docs/vault.md, \"Vault\")" >&2; exit 1; }
}

render() {
  [ $# -gt 0 ] || { echo "usage: VAULT_TOKEN=... scripts/stack.sh render <service>..." >&2; exit 2; }
  : "${VAULT_TOKEN:?VAULT_TOKEN is required: a Vault token allowed to read secret/env/* (docs/vault.md, \"Vault\")}"
  umask 077
  mkdir -p .env.vault
  for service in "$@"; do
    case $service in host) paths="myid-adapter host" ;; *) paths=$service ;; esac
    json=""
    for path in $paths; do
      data=$(vault_compose exec -T -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_CACERT=/vault/ca/ca.pem -e VAULT_TOKEN vault \
        vault kv get -format=json "secret/env/$path" 2> /dev/null) \
        || { echo "secret/env/$path can't be read: not written yet, or the token may not read it (docs/settings.md, \"Settings\")" >&2; exit 1; }
      json="$json$(printf '%s' "$data" | jq .data.data)"
    done
    printf '%s' "$json" | jq -s add > ".env.vault/$service.json.tmp"
    [ "$(jq length ".env.vault/$service.json.tmp")" -gt 0 ] || { echo "secret/env/$service is empty" >&2; exit 1; }
    jq -r 'to_entries[] | .key + "=" + (.value
      | if test("^[A-Za-z0-9_./:@,+%=-]*$") then . else "\"" + gsub("(?<c>[\"$\\\\])"; "\\\(.c)") + "\"" end)' \
      ".env.vault/$service.json.tmp" > ".env.vault/$service.env.tmp"
    mv ".env.vault/$service.json.tmp" ".env.vault/$service.json"
    mv ".env.vault/$service.env.tmp" ".env.vault/$service.env"
    echo "rendered .env.vault/$service.env"
  done
}

choices() {
  render stack
  mailpit=$(jq -r '.MAILPIT // empty' .env.vault/stack.json)
  case $mailpit in
    on) profiles="--profile mailpit" ;;
    off) profiles=""; compose --profile mailpit rm -sf mailpit > /dev/null ;;
    *) echo "secret/env/stack MAILPIT must be on or off, not \"$mailpit\"" >&2; exit 1 ;;
  esac
}

pull_images() {
  attempts=$(jq -r '.PULL_ATTEMPTS // empty' .env.vault/stack.json)
  wait=$(jq -r '.PULL_RETRY_SECONDS // empty' .env.vault/stack.json)
  [ -n "$attempts" ] && [ -n "$wait" ] \
    || { echo "secret/env/stack needs PULL_ATTEMPTS and PULL_RETRY_SECONDS: t apply after adding them to secret/input/heeyid (docs/settings.md, \"Settings\")" >&2; exit 1; }
  try=1
  until compose $profiles --profile apps pull --quiet --policy "$pull"; do
    [ "$try" -lt "$attempts" ] || { echo "pulling the images failed $attempts times: check the registry and the login (docker login ghcr.io), then run it again" >&2; exit 1; }
    echo "pulling the images failed (try $try of $attempts); again in $wait s" >&2
    sleep "$wait"
    try=$((try + 1))
  done
}

settings() {
  vault_up
  vault_ready
  vault_tls_renew
  render postgres valkey keycloak keycloak-config observability mailpit myid-adapter sms-adapter taf-adapter push-adapter callbacks
  cert_list
  choices
  pull_images
  pull=never # every image is here now
}

up() {
  settings
  if [ $# -gt 0 ]; then
    start "$@"
    return
  fi
  wait_up $profiles
  wait_up $profiles --profile apps
}

start() {
  config=$(compose $profiles --profile apps config --format json)
  for service in "$@"; do
    case $(printf '%s' "$config" | jq -r --arg s "$service" '.services[$s].restart // empty') in
      unless-stopped) compose $profiles --profile apps up -d --wait --pull "$pull" "$service" ;;
      no)
        compose $profiles --profile apps up -d --pull "$pull" "$service"
        code=$(docker wait "$(compose $profiles --profile apps ps -aq "$service")")
        [ "$code" = 0 ] || { echo "$service exited with $code: scripts/stack.sh logs $service" >&2; exit 1; } ;;
      *) echo "$service: no such service here (with the choices made)" >&2; exit 2 ;;
    esac
  done
}

cert_list() {
  : "${VAULT_TOKEN:?VAULT_TOKEN is required}"
  list=$(mktemp); pems=$(mktemp -d)
  pem_ends() {
    rm -f "$pems"/c.*.pem
    awk -v dir="$pems" '/BEGIN CERTIFICATE/ { n++ } n { print > (dir "/c." n ".pem") }' "$1"
    n=1
    while [ -e "$pems/c.$n.pem" ]; do
      suffix=""; [ "$n" -eq 1 ] || suffix="#$n"
      end=$(openssl x509 -noout -enddate -in "$pems/c.$n.pem" 2> /dev/null) \
        && printf '%s|%s%s\n' "${end#notAfter=}" "$2" "$suffix" >> "$list"
      n=$((n + 1))
    done
  }
  for json in .env.vault/*.json; do
    service=$(basename "$json" .json)
    for key in $(jq -r 'to_entries[] | select((.value | type) == "string" and (.value | contains("BEGIN CERTIFICATE"))) | .key' "$json"); do
      jq -r --arg k "$key" '.[$k]' "$json" > "$pems/value.pem"
      pem_ends "$pems/value.pem" "$service/$key"
    done
  done
  vault_compose exec -T -e VAULT_ADDR=https://127.0.0.1:8200 -e VAULT_CACERT=/vault/ca/ca.pem -e VAULT_TOKEN vault sh -c '
    set -e
    serials=$(vault list -format=json pki/certs) # unreadable: stops here, not an empty list
    for serial in $(printf "%s" "$serials" | tr -d "[]\", "); do
      [ "$(vault read -field=revocation_time "pki/cert/$serial")" = 0 ] || continue
      vault read -field=certificate "pki/cert/$serial"; echo
    done' > "$pems/issued.pem" 2> /dev/null \
    || { echo "pki/certs can't be listed: the token lacks policy cert-watch (helpers' render_token makes one with it)" >&2; exit 1; }
  callers=$(jq -r '.MYID_ADAPTER_CALLERS' .env.vault/keycloak-config.json | tr ',' '\n')
  awk -v dir="$pems" '/BEGIN CERTIFICATE/ { n++ } n { print > (dir "/issued." n ".pem") }' "$pems/issued.pem"
  for pem in "$pems"/issued.[0-9]*.pem; do
    [ -e "$pem" ] || continue
    name=$(openssl x509 -noout -subject -nameopt RFC2253 -in "$pem" | sed 's/.*CN=\([^,]*\).*/\1/')
    case $name in
      myid-adapter | sms-adapter | taf-adapter | push-adapter | heeyid-keycloak | vault | observability | mailpit | "heeyid unit CA") ;;
      *) printf '%s\n' "$callers" | grep -qxF "$name" || continue ;;
    esac
    end=$(openssl x509 -noout -enddate -in "$pem")
    printf '%s|pki/%s\n' "${end#notAfter=}" "$name" >> "$list"
  done
  cat "$list" > .env.vault/cert-expiry.txt
  rm -rf "$list" "$pems"
  echo "certificates to watch: $(wc -l < .env.vault/cert-expiry.txt | tr -d ' ')"
}

deploy() {
  pull=always # a tag like main moves: the image published last, not the one this host has
  up
  compose $profiles --profile apps rm -f $(compose $profiles --profile apps config --format json \
    | jq -r '.services | to_entries[] | select(.value.restart == "no") | .key') > /dev/null
  active=$( { compose $profiles --profile apps config --images; vault_compose config --images; } | sort -u)
  named=$( { compose --profile '*' config --images; vault_compose config --images; } | sed 's/:[^:/]*$//' | sort -u)
  in_use=$(docker ps -a --format '{{.Image}}' | sort -u)
  for repository in $named; do
    for image in $(docker images --format '{{.Repository}}:{{.Tag}}' "$repository" | grep -v ':<none>$'); do
      printf '%s\n' "$active" "$in_use" | grep -qxF "$image" && continue
      docker rmi "$image" > /dev/null
      echo "removed image $image"
    done
  done
}

wait_up() {
  compose "$@" up -d --wait --remove-orphans --pull "$pull" $(compose "$@" config --format json \
    | jq -r '.services | to_entries[] | select(.value.restart == "unless-stopped") | .key')
}

case "${1:?usage: scripts/stack.sh up [<service>...]|settings|deploy|vault-up|render|<compose args>}" in
  up) shift; up "$@" ;;
  settings) settings ;;
  deploy) deploy ;;
  vault-up) vault_up ;;
  render) shift; render "$@" ;;
  *) compose "$@" ;;
esac
