#!/usr/bin/env bash
set -euo pipefail
HERE=$PWD # relative paths the operator gives (answers file, PEM files) are from where they ran it
cd "$(dirname "$0")/.."
trap 'status=$?; [ $status -eq 0 ] || printf "\033[31minstall: stopped. Fix what is above, then run it again: it goes on from there.\033[0m\n" >&2' EXIT

UNIT=heeyid
. scripts/helpers.sh # v, t, root, apply: the same helpers the operator uses
INPUTS=scripts/inputs.json
ANSWERS=

say() { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31minstall: %s\033[0m\n' "$*" >&2; exit 1; }
tty() { [ -t 0 ]; }
path() { case $1 in /*) printf '%s' "$1" ;; "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;; *) printf '%s/%s' "$HERE" "$1" ;; esac; }

ask() {
  tty || die "$1: no terminal to ask on; give it in the answers file (--answers)"
  local reply
  if [ "${2:-}" = secret ]; then
    printf '%s (typed unseen): ' "$1" > /dev/tty; IFS= read -rs reply; printf '\n' > /dev/tty
  else
    printf '%s: ' "$1" > /dev/tty; IFS= read -r reply
  fi
  REPLY=$reply
}

tofu_apply() {
  local out
  out=$(t apply -input=false -auto-approve -compact-warnings "$@" < /dev/null 2>&1) || { printf '%s\n' "$out"; die "OpenTofu's apply failed (above)"; }
  printf '%s\n' "$out" | grep -E '^(Apply complete|No changes)'
}
seal_status() {
  local status
  status=$(v status -format=json < /dev/null 2> /dev/null || true)
  printf '%s' "$status" | jq -e 'has("initialized")' > /dev/null 2>&1 \
    || die "Vault doesn't answer inside its container (scripts/stack.sh vault-up; docker compose -f vault/docker-compose.yml logs vault)"
  printf '%s' "$status"
}
initialized() {
  local status
  status=$(seal_status) || exit 1
  printf '%s' "$status" | jq -e .initialized > /dev/null
}

unseal() {
  local status share result
  status=$(seal_status)
  while printf '%s' "$status" | jq -e .sealed > /dev/null; do
    say "Vault is sealed: $(printf '%s' "$status" | jq -r '"\(.progress) of \(.t)"') shares given. Each keyholder types theirs."
    ask "Unseal share" secret; share=$REPLY
    result=$(KEY=$share jq -n '{key: env.KEY}' | vapi sys/unseal)
    [ -n "$result" ] || say "Vault refused that share, or didn't answer."
    status=$(seal_status)
  done
  say "Vault is unsealed."
}

generate_root() {
  local attempt nonce otp result share
  v operator generate-root -cancel < /dev/null > /dev/null 2>&1
  attempt=$(printf '{}' | vapi sys/generate-root/attempt)
  nonce=$(printf '%s' "$attempt" | jq -r '.nonce // empty'); otp=$(printf '%s' "$attempt" | jq -r '.otp // empty')
  [ -n "$nonce" ] || die "Vault didn't start a root-token attempt: is it unsealed and running? (docker compose -f vault/docker-compose.yml logs vault)"
  say "A root token from three keyholders' shares."
  while :; do
    ask "Unseal share" secret; share=$REPLY
    result=$(KEY=$share NONCE=$nonce jq -n '{key: env.KEY, nonce: env.NONCE}' | vapi sys/generate-root/update)
    [ "$(printf '%s' "$result" | jq -r '.complete // empty')" = true ] && break
    [ -n "$result" ] || { say "Vault refused that share, or didn't answer."; continue; }
    printf '%s' "$result" | jq -r '"\(.progress) of \(.required) shares"'
  done
  VAULT_TOKEN=$(printf '%s' "$result" | jq -r .encoded_token | v operator generate-root -decode=- -otp="$otp")
  export VAULT_TOKEN
}

is_root() { v token lookup -format=json < /dev/null 2> /dev/null | jq -e '.data.policies | index("root")' > /dev/null; }

root_token() {
  [ -n "${VAULT_TOKEN:-}" ] && is_root && return
  while :; do
    ask "Root token (Enter: make one from three keyholders' shares)" secret
    if [ -z "$REPLY" ]; then generate_root; else VAULT_TOKEN=$REPLY; export VAULT_TOKEN; fi
    is_root && return
    say "That token isn't a root token of this Vault."
  done
}

vault_open() {
  scripts/stack.sh vault-up < /dev/null
  initialized || vault_init
  unseal
  root_token
}

vault_init() {
  say "Vault is new. Initialising it shows five unseal shares and a root token, once. Each of the five"
  say "keyholders saves their own share in their password manager, then pastes it back here to prove it."
  ask "Press Enter when the keyholders are here"
  local init share n=0
  init=$(printf '{"secret_shares": 5, "secret_threshold": 3}' | vapi sys/init)
  printf '%s' "$init" | jq -e .root_token > /dev/null || die "Vault's init failed: $init"
  printf '\n'
  printf '%s' "$init" | jq -r '.keys_base64 | to_entries[] | "  share \(.key + 1): \(.value)"'
  printf '%s' "$init" | jq -r '"  root token: \(.root_token)   (this install only; revoked at its end)"'
  printf '\n'
  VAULT_TOKEN=$(printf '%s' "$init" | jq -r .root_token); export VAULT_TOKEN
  while [ $n -lt 5 ]; do
    share=$(printf '%s' "$init" | jq -r ".keys_base64[$n]")
    ask "Share $((n + 1)), pasted back from where it is saved" secret
    if [ "$(printf '%s' "$REPLY" | tr -d '[:space:]')" = "$share" ]; then
      say "Share $((n + 1)) is saved."; n=$((n + 1))
    else
      say "That isn't share $((n + 1)). It is still on screen: save it again, then paste it back."
    fi
  done
  init= share=
  ask "Every share is saved. Press Enter to clear the screen; then three keyholders unseal"
  printf '\033[3J\033[H\033[2J' > /dev/tty
}

passphrase() {
  [ -z "${TF_VAR_state_passphrase:-}" ] || return 0
  if [ -f vault/tofu/terraform.tfstate ]; then
    ask "State passphrase" secret
  else
    say "Choose the state passphrase (at least 16 characters); keep it with the operator and a deputy."
    while :; do
      ask "State passphrase" secret; local first=$REPLY
      [ ${#first} -ge 16 ] || { say "At least 16 characters."; continue; }
      ask "The same again" secret
      [ "$REPLY" = "$first" ] && break
      say "They differ."
    done
  fi
  TF_VAR_state_passphrase=$REPLY; export TF_VAR_state_passphrase
}

answered() {
  [ -n "$ANSWERS" ] && grep -q "^$1=" "$ANSWERS" || return 1
  local value
  value=$(sed -n "s/^$1=//p" "$ANSWERS" | head -n 1)
  case $value in
    @*) cat "$(path "${value#@}")" ;;
    *) printf '%s' "$value" ;;
  esac
}

valid() {
  local spec=$1 value=$2 format
  format=$(printf '%s' "$spec" | jq -r .format)
  if [ -z "$value" ]; then
    printf '%s' "$spec" | jq -e '.empty == true' > /dev/null && return 0
    say "It can't be empty."; return 1
  fi
  case $format in
    certificate)
      printf '%s' "$value" | openssl x509 -noout 2> /dev/null || { say "Not a PEM certificate."; return 1; }
      printf '%s' "$value" | openssl x509 -noout -checkend 0 > /dev/null || { say "That certificate has expired."; return 1; } ;;
    key)
      printf '%s' "$value" | openssl pkey -noout -passin pass: 2> /dev/null || { say "Not a PEM private key without a passphrase."; return 1; } ;;
    service-account)
      printf '%s' "$value" | jq -e '.type == "service_account" and (.project_id | type) == "string" and (.client_email | type) == "string"
        and (.private_key | type) == "string" and .token_uri == "https://oauth2.googleapis.com/token"' > /dev/null 2>&1 \
        || { say "Not a Google service account's JSON key (type service_account, project_id, client_email, private_key, token_uri)."; return 1; } ;;
    *)
      case $value in *'
'*) say "One line only."; return 1 ;; esac
      printf '%s' "$value" | grep -Eq -- "$format" || { say "It must match $format ($(printf '%s' "$spec" | jq -r .what))."; return 1; } ;;
  esac
}

obtain() {
  local spec=$1 name value format
  BACK=
  name=$(printf '%s' "$spec" | jq -r .name); format=$(printf '%s' "$spec" | jq -r .format)
  if value=$(answered "$name"); then
    valid "$spec" "$value" || die "$ANSWERS: $name is not valid"
    VALUE=$value; return
  fi
  printf '\n\033[1m%s\033[0m: %s\n' "$name" "$(printf '%s' "$spec" | jq -r .what)" > /dev/tty
  printf '%s' "$spec" | jq -r '(if .suggested then "  Enter: \(.example), or type another" else "  e.g. \(.example)" end) + "   (< goes back)"' > /dev/tty
  while :; do
    case $format in
      certificate | key | service-account)
        ask "$name, the file's path"
        [ "$REPLY" != "<" ] || { BACK=1; return; }
        if [ -z "$REPLY" ] && printf '%s' "$spec" | jq -e '.empty == true' > /dev/null; then value=""
        elif [ -r "$(path "$REPLY")" ]; then value=$(cat "$(path "$REPLY")"); else say "No such file."; continue; fi ;;
      *)
        if printf '%s' "$spec" | jq -e .secret > /dev/null; then ask "$name" secret; else ask "$name"; fi
        [ "$REPLY" != "<" ] || { BACK=1; return; }
        value=$REPLY
        [ -n "$value" ] || value=$(printf '%s' "$spec" | jq -r 'if .suggested then .example else "" end') ;;
    esac
    valid "$spec" "$value" && break
  done
  VALUE=$value
}

ask_list() {
  local list=$1 after=$2 n i=0 spec
  n=$(printf '%s' "$list" | jq length)
  while [ $i -lt "$n" ]; do
    spec=$(printf '%s' "$list" | jq -c ".[$i]")
    obtain "$spec"
    if [ -n "$BACK" ]; then
      [ $i -eq 0 ] || i=$((i - 1))
      continue
    fi
    ASKED=$(printf '%s' "$spec" | jq -r .name)
    VALUES=$(printf '%s' "$VALUES" | V=$VALUE jq -c --arg k "$ASKED" '. + {($k): env.V}')
    "$after"
    i=$((i + 1))
  done
}

review() {
  local list=$1 after=$2 n spec
  tty && [ -z "$ANSWERS" ] || return 0
  n=$(printf '%s' "$list" | jq length)
  while :; do
    printf '\n\033[1mThe answers\033[0m\n' > /dev/tty
    printf '%s' "$list" | V=$VALUES jq -r '(env.V | fromjson) as $v | to_entries[] | .value as $s | ($v[$s.name] // "") as $x
      | "  \(.key + 1). \($s.name) = \(if $x == "" then "(empty)" elif $s.secret then "••••" elif ($s.format == "certificate" or $s.format == "key") then "(PEM)" elif $s.format == "service-account" then "(JSON)" else $x end)"' > /dev/tty
    ask "A number to change, or Enter when every answer is right"
    [ -n "$REPLY" ] || return 0
    case $REPLY in
      0* | *[!0-9]*) say "A number from 1 to $n."; continue ;;
    esac
    [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$n" ] || { say "A number from 1 to $n."; continue; }
    spec=$(printf '%s' "$list" | jq -c ".[$((REPLY - 1))]")
    obtain "$spec"
    [ -z "$BACK" ] || continue
    ASKED=$(printf '%s' "$spec" | jq -r .name)
    VALUES=$(printf '%s' "$VALUES" | V=$VALUE jq -c --arg k "$ASKED" '. + {($k): env.V}')
    "$after"
  done
}

env_local() {
  step "Release and the consoles' door (.env.local)"
  local name
  for name in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env.local 2> /dev/null); do
    jq -e --arg n "$name" 'any(.[]; .name == $n and .file == ".env.local")' "$INPUTS" > /dev/null \
      || die ".env.local has $name, which nothing reads: remove the line (docs/settings.md, \"Settings\" lists what .env.local holds)"
  done
  for name in $(jq -r '.[] | select(.file == ".env.local") | .name' "$INPUTS"); do
    [ -n "$(env_local_value "$name")" ] || ! grep -q "^$name=" .env.local 2> /dev/null \
      || die ".env.local has $name empty: give it a value or remove the line"
  done
  VALUES='{}'
  touch .env.local
  local have missing
  have=$(sed -n 's/^\([A-Z_]*\)=..*/\1/p' .env.local)
  missing=$(E=$have jq -c '(env.E | split("\n")) as $have | [.[] | select(.file == ".env.local") | select(.name as $n | $have | index($n) | not)]' "$INPUTS")
  ask_list "$missing" env_local_store
  sed 's/^/  /' .env.local
}
env_local_store() {
  { grep -v "^$ASKED=" .env.local || true; printf '%s=%s\n' "$ASKED" "$VALUE"; } > .env.local.new
  mv .env.local.new .env.local
}

INPUT='{}' # secret/input/<unit> as Vault holds it; secrets live in this process only
input_value() { printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty'; }
input_write() { printf '%s' "$INPUT" | v kv put "secret/input/$UNIT" - > /dev/null; }
input_store() { INPUT=$VALUES; input_write; }

inputs() {
  step "The environment's values (secret/input/$UNIT)"
  local read status=0
  read=$(v kv get -format=json "secret/input/$UNIT" < /dev/null 2> /dev/null) || status=$?
  case $status in
    0) INPUT=$(printf '%s' "$read" | jq -c .data.data) ;;
    2) INPUT='{}' ;;
    *) die "secret/input/$UNIT can't be read (exit $status): is Vault unsealed, and the token a root token?" ;;
  esac
  local all missing asked
  all=$(jq -c '[.[] | select(.file == null)]' "$INPUTS")
  missing=$(printf '%s' "$all" | H=$INPUT jq -c '(env.H | fromjson) as $have | [.[] | select(.name as $n | $have | has($n) | not)]')
  asked=$(printf '%s' "$missing" | jq length)
  VALUES=$INPUT
  [ "$asked" -eq 0 ] || ! tty || [ -n "$ANSWERS" ] || say "Type < at any question to go back to the one before."
  ask_list "$missing" input_store
  review "$all" input_store
  say "Every value is there ($asked asked now; $(printf '%s' "$INPUT" | jq length) in all)."
}

version_number() { printf '%s' "$1" | sed 's/^v//; s/[^0-9.].*//' | awk -F. '{ printf "%d%03d%03d", $1, $2, $3 }'; }

preflight() {
  step "Preflight"
  local tool
  for tool in docker jq openssl curl; do
    command -v "$tool" > /dev/null || die "$tool is missing: install it (the guide, section 1)"
  done
  docker info > /dev/null 2>&1 || die "Docker doesn't answer: start it, or use an account allowed to run it"
  local compose
  compose=$(docker compose version --short 2> /dev/null) || die "Docker Compose v2 is missing (docker compose): install the plugin"
  [ "$(version_number "$compose")" != "$(version_number 2.32.0)" ] \
    || die "Docker Compose 2.32.0 recreates Vault on every up, which seals it: install another version (known good: 2.31.0, 2.32.1, 2.32.4, 5.6.1)"
  [ "$(version_number "$compose")" -ge "$(version_number 2.24.0)" ] \
    || die "Docker Compose $compose is too old (env_file required: needs 2.24.0): install a newer one (known good: 2.31.0, 2.32.1, 2.32.4, 5.6.1)"
  say "Docker $(docker version --format '{{.Server.Version}}'), Compose $compose, jq, openssl, curl."
}

ports() {
  local address port taken= ours id project name
  ours=$(for project in heeyid heeyid-vault; do
    for id in $(docker ps -q --filter "label=com.docker.compose.project=$project"); do
      docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$id"
    done
  done | tr ' ' '\n')
  for address in $(for name in CONSOLES_ADDRESS CALLBACKS_ADDRESS; do
    grep -ho "$name is required}:[0-9]*" docker-compose.yml vault/docker-compose.yml | sed "s/.*}:/$(env_local_value $name):/"
  done); do
    port=${address##*:}; address=${address%:*}
    printf '%s\n' "$ours" | grep -q ":$port\$" && continue
    [ "$address" = 0.0.0.0 ] && address=127.0.0.1
    (exec 3<> "/dev/tcp/$address/$port") 2> /dev/null || continue
    taken="$taken $address:$port"
  done
  [ -z "$taken" ] || die "taken by something other than heeyID:$taken. Free them, or change .env.local"
  say "Ports free (or heeyID's)."
}

images() {
  local version image
  version=$(env_local_value HEEYID_VERSION)
  for image in myid-adapter sms-adapter taf-adapter push-adapter; do
    docker image inspect "ghcr.io/khakimjanovich/$image:$version" > /dev/null 2>&1 && continue
    docker manifest inspect "ghcr.io/khakimjanovich/$image:$version" > /dev/null 2>&1 \
      || die "can't read ghcr.io/khakimjanovich/$image:$version: log in (docker login ghcr.io, a token with read:packages; the guide, section 3, step 2) or check HEEYID_VERSION"
  done
  say "The images of $version are readable."
}

answers_file() {
  local file value
  file=$(path "$1")
  [ -r "$file" ] || die "$1: no such file"
  case $(ls -ldL "$file" | cut -c5-10) in ------) ;; *) die "$1 is readable by others: chmod 600 $1" ;; esac
  while IFS= read -r value; do
    [ -r "$(path "$value")" ] || die "$1: @$value: no such file"
  done < <(sed -n 's/^[A-Z_]*=@//p' "$file")
  ANSWERS=$file
}

check() {
  step "Health check"
  local status bad
  status=$(seal_status) || exit 1
  printf '%s' "$status" | jq -e '.sealed == false' > /dev/null || die "Vault is sealed (the guide, section 7)"
  bad=$(docker ps -a --filter label=com.docker.compose.project=heeyid --format '{{.Names}}: {{.Status}}' \
    | grep -v '(healthy)' | grep -v 'Exited (0)' || true)
  [ -z "$bad" ] || die "not healthy: $bad"
  [ -s .env.vault/myid-adapter.env ] || die ".env.vault is missing: the stack hasn't started (scripts/install.sh)"
  docker ps -a --filter label=com.docker.compose.project=heeyid --format '  {{.Names}}: {{.Status}}'
  say "Healthy."
}

close_session() {
  local stamp
  stamp=$(date +%F-%H%M)
  mkdir -p "$HOME/backups"
  v operator raft snapshot save /tmp/vault.snap < /dev/null
  docker compose --env-file .env.local -f vault/docker-compose.yml cp vault:/tmp/vault.snap "$HOME/backups/heeyid-vault-$stamp.snap"
  docker compose --env-file .env.local -f vault/docker-compose.yml exec -T vault rm -f /tmp/vault.snap < /dev/null
  [ ! -f vault/tofu/terraform.tfstate ] || cp vault/tofu/terraform.tfstate "$HOME/backups/heeyid-tfstate-$stamp"
  v token revoke -self < /dev/null > /dev/null
  unset VAULT_TOKEN
  say "Backed up to ~/backups (heeyid-vault-$stamp.snap, heeyid-tfstate-$stamp): copy them to the bank's backup storage."
  say "The root token is revoked."
}

PROGRESS=.install/progress
ACCESS_LIST=.install/access.txt
WAVES="host vault postgres valkey keycloak observability services"

confirmed() { grep -q "^$1 " "$PROGRESS" 2> /dev/null; }

wave() {
  if confirmed "$1"; then
    say "== $2: confirmed $(sed -n "s/^$1 //p" "$PROGRESS")"
    return
  fi
  step "$2"
  "wave_$1"
  printf '\n\033[1mHow to get in\033[0m\n'
  "access_$1"
  while :; do
    ask "Try it yourself, then type ok (Ctrl-C stops here: a run again starts at this wave)"
    [ "$REPLY" = ok ] && break
  done
  mkdir -p .install
  printf '%s %s\n' "$1" "$(date -u +%FT%TZ)" >> "$PROGRESS"
}

consoles() { env_local_value CONSOLES_ADDRESS; }
console() { printf 'https://%s.%s' "$1" "$(env_local_value CONSOLES_DOMAIN)"; }
console_names() { sed -n 's/^ *\([a-z]*\)\.\${CONSOLES_DOMAIN} .*/\1/p' consoles/names.conf.stream-template; }
ccurl() { curl -s --noproxy '*' --cacert .env.vault/vault-ca.pem "$@"; }
leads_here() {
  local host ip
  host=$(console "$1"); host=${host#https://}
  ip=$(curl -sk --noproxy '*' -o /dev/null -w '%{remote_ip}' "https://$host/" || true)
  [ "$ip" = "$(consoles)" ] \
    || die "$host leads to ${ip:-no address}, not $(consoles): the name must resolve to CONSOLES_ADDRESS (the bank's DNS record *.$(env_local_value CONSOLES_DOMAIN), or on a lone machine this line in /etc/hosts: $(hosts_line))"
}

stack() {
  local token status=0
  token=$(render_token 15m) || die "no render token: the root token is no longer valid; run it again"
  VAULT_TOKEN=$token scripts/stack.sh "$@" < /dev/null || status=$?
  revoke "$token"
  return $status
}

revoke() {
  (VAULT_TOKEN=$1; export VAULT_TOKEN; v token revoke -self < /dev/null > /dev/null) \
    || say "A short-lived token couldn't be revoked; it expires by itself within 15 minutes."
}

clipboard() {
  local tool
  for tool in pbcopy wl-copy 'xclip -selection clipboard'; do
    command -v "${tool%% *}" > /dev/null && { printf '%s' "$tool"; return; }
  done
  return 0
}

group() { jq -er --arg k "$1" '.[$k]' .env.vault/keycloak-config.json || die "$1 is missing from .env.vault/keycloak-config.json: scripts/stack.sh settings"; }

wave_host() {
  ports
  images
}
hosts_line() {
  local name line
  line=$(consoles)
  for name in $(console_names); do line="$line $(console "$name" | sed 's|https://||')"; done
  printf '%s' "$line"
}
access_host() {
  say "  Consoles        by name, through one door on $(consoles):443; each device that opens one resolves"
  say "                  the names to $(consoles): the bank's DNS (one record, *.$(env_local_value CONSOLES_DOMAIN)), or on a"
  say "                  lone machine this line in /etc/hosts (the installer never edits it):"
  say "                  $(hosts_line)"
  say "                  CONSOLES_ADDRESS must stay fixed: a static address, or a DHCP reservation"
}

wave_vault() {
  vault_open
  passphrase
  local out
  out=$(t init -input=false < /dev/null 2>&1) || { printf '%s\n' "$out"; die "OpenTofu's init failed (above)"; }
  v secrets list -format=json < /dev/null | jq -e 'has("secret/")' > /dev/null \
    || tofu_apply -target=vault_mount.secret
  inputs
  step "Every service's settings (vault/tofu)"
  tofu_apply
  stack settings || die "the settings can't be rendered or the images pulled (above)"
  stack up heeyid-consoles || die "the consoles' door didn't start (above): scripts/stack.sh logs heeyid-consoles"
  leads_here vault
  local tries=0
  until ccurl -f "$(console vault)/v1/sys/health" > /dev/null; do
    tries=$((tries + 1))
    [ $tries -lt 10 ] || die "$(console vault) doesn't serve a certificate from heeyID's CA for its name: run it again (its settings install it)"
    sleep 1
  done
  say "$(console vault) leads to $(consoles), through the consoles' door to Vault, with heeyID's certificate."
  local token status=0
  token=$(render_token 5m)
  (VAULT_TOKEN=$token; export VAULT_TOKEN
    v kv get secret/env/stack < /dev/null > /dev/null || exit 1
    ! v kv get secret/input/heeyid < /dev/null > /dev/null 2>&1 || exit 2) || status=$?
  revoke "$token"
  case $status in
    0) say "A settings-only token reads secret/env/stack and is refused secret/input/heeyid." ;;
    1) die "a settings-only token can't read secret/env/stack: policy env-read (vault/policies) isn't what OpenTofu wrote; t apply" ;;
    *) die "a settings-only token reads secret/input/heeyid: policy env-read gives too much (vault/policies)" ;;
  esac
}
access_vault() {
  say "  Vault           $(console vault)/ui, method Token: a root token from three keyholders' shares,"
  if [ -n "$(clipboard)" ]; then
    say "                  in another terminal in this folder: . scripts/helpers.sh && root && printf %s \"\$VAULT_TOKEN\" | $(clipboard)"
    say "                  Paste it; when done: v token revoke -self"
  else
    say "                  which this host can't copy to a browser (no clipboard): use Vault from this host's terminal,"
    say "                  . scripts/helpers.sh && root, then v ... (docs/vault.md, \"Vault\"); when done: v token revoke -self"
  fi
  say "  Every console   heeyID's CA, .env.vault/vault-ca.pem ($(openssl x509 -noout -fingerprint -sha256 -in .env.vault/vault-ca.pem | cut -d= -f2)):"
  say "                  trust it on each device that opens a console, or its browser warns"
}

wave_postgres() {
  stack up postgres postgres-init || die "Postgres didn't start (above): scripts/stack.sh logs postgres postgres-init"
  PGPASSWORD=$(jq -r '.KEYCLOAK_DB_PASSWORD' .env.vault/postgres.json) scripts/stack.sh exec -T -e PGPASSWORD postgres \
    psql -h postgres -U keycloak -d keycloak -Atc 'select 1' < /dev/null > /dev/null \
    || die "user keycloak can't sign in to database keycloak with its password (secret/env/postgres): scripts/stack.sh up postgres-init sets it again"
  say "User keycloak signs in to its database keycloak with its password."
}
access_postgres() {
  say "  Postgres        no published port: Keycloak's database only, for now. Break-glass, from this"
  say "                  host and logged: scripts/stack.sh exec postgres psql -U heeyid_admin -d heeyid"
}

wave_valkey() {
  stack up valkey || die "Valkey didn't start (above): scripts/stack.sh logs valkey"
  local user password ok refused
  for user in myid-adapter sms-adapter taf-adapter; do
    password=$(jq -r --arg k "VALKEY_$(printf '%s' "$user" | tr '[:lower:]-' '[:upper:]_')_PASSWORD" '.[$k]' .env.vault/valkey.json)
    cli() { REDISCLI_AUTH=$password scripts/stack.sh exec -T -e REDISCLI_AUTH valkey valkey-cli --user "$user" "$@" < /dev/null 2>&1; }
    ok=$(cli set "$user:install:probe" 1 EX 10)
    [ "$ok" = OK ] || die "user $user can't write its own keys ($user:*): $ok (valkey/start.sh)"
    refused=$(cli set t:install:other:probe 1 EX 10)
    case $refused in *NOPERM*) ;; *) die "user $user writes keys outside $user:*: valkey/start.sh gives too much" ;; esac
  done
  refused=$(scripts/stack.sh exec -T valkey valkey-cli ping < /dev/null 2>&1)
  case $refused in *NOAUTH* | *NOPERM* | *WRONGPASS*) ;; *) die "Valkey answers without a sign-in ($refused): the default user must be off (valkey/start.sh)" ;; esac
  say "Users myid-adapter, sms-adapter and taf-adapter write their own keys only; Valkey answers nobody without a sign-in."
}
access_valkey() {
  say "  Valkey          no published port: each service as its own ACL user (valkey/start.sh)"
}

wave_keycloak() {
  stack up heeyid-keycloak keycloak-config || die "Keycloak didn't start (above): scripts/stack.sh logs heeyid-keycloak keycloak-config"
  local kc token page
  leads_here keycloak
  kc=$(console keycloak)
  token=$(jq -r '"grant_type=client_credentials&client_id=customer-gateway&client_secret=\(.CUSTOMER_GATEWAY_CLIENT_SECRET)"' .env.vault/keycloak-config.json \
    | ccurl --data @- "$kc/realms/services/protocol/openid-connect/token" | jq -r '.access_token // empty')
  [ -n "$token" ] || die "customer-gateway's client gets no token at $kc (realm services): scripts/stack.sh logs heeyid-keycloak keycloak-config"
  printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+' | { base64 -d 2> /dev/null || true; } \
    | jq -e '(.aud | if type == "array" then . else [.] end) as $aud | ($aud | index("myid-adapter")) and ($aud | index("sms-adapter")) and ($aud | index("taf-adapter"))
      and (.realm_access.roles | index("myid.use")) and (.realm_access.roles | index("sms.use")) and (.realm_access.roles | index("taf.use"))' > /dev/null 2>&1 \
    || die "customer-gateway's token lacks the audiences myid-adapter, sms-adapter and taf-adapter or the roles myid.use, sms.use and taf.use (keycloak/services-realm.json)"
  say "customer-gateway's client gets a token from realm services for myid-adapter, sms-adapter and taf-adapter, with the roles myid.use, sms.use and taf.use."
  token=$(jq -r '"grant_type=client_credentials&client_id=workers&client_secret=\(.WORKERS_CLIENT_SECRET)"' .env.vault/keycloak-config.json \
    | ccurl --data @- "$kc/realms/services/protocol/openid-connect/token" | jq -r '.access_token // empty')
  [ -n "$token" ] || die "workers' client gets no token at $kc (realm services): scripts/stack.sh logs heeyid-keycloak keycloak-config"
  printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+' | { base64 -d 2> /dev/null || true; } \
    | jq -e '(.aud | if type == "array" then . else [.] end) as $aud | ($aud | index("myid-adapter")) and ($aud | index("push-adapter"))
      and (.realm_access.roles | index("myid.use")) and (.realm_access.roles | index("push.use"))' > /dev/null 2>&1 \
    || die "workers' token lacks the audiences myid-adapter and push-adapter or the roles myid.use and push.use (keycloak/services-realm.json)"
  say "workers' client gets a token from realm services for myid-adapter and push-adapter, with the roles myid.use and push.use."
  page=$(ccurl "$kc/realms/people/protocol/openid-connect/auth?client_id=grafana&response_type=code&scope=openid&redirect_uri=$(console grafana | sed 's|:|%3A|; s|/|%2F|g')%2Flogin%2Fgeneric_oauth&code_challenge=$(printf '%043d' 0)&code_challenge_method=S256")
  printf '%s' "$page" | grep -q 'name="username"' \
    || die "realm people shows no sign-in page for Grafana at $kc: keycloak-config sets its grafana client (scripts/stack.sh logs keycloak-config)"
  [ "$(ccurl -o /dev/null -w '%{http_code}' "$kc/admin/master/console/")" = 200 ] || die "Keycloak's console doesn't answer at $kc/admin"
  page=$(ccurl "$kc/admin/master/console/")
  printf '%s' "$page" | grep -q "\"authServerUrl\": *\"$kc\"" \
    || die "Keycloak's console sends the browser to $(printf '%s' "$page" | sed -n 's/.*"authServerUrl": *"\([^"]*\)".*/\1/p'), not $kc: realm master's frontendUrl (keycloak/configure.sh; scripts/stack.sh up keycloak-config)"
  say "Realm people's sign-in page and the admins' console answer on $kc, with heeyID's certificate."
}
access_keycloak() {
  say "  Keycloak        $(console keycloak)/admin: the members of $(group LDAP_ADMINS_GROUP_DN),"
  say "                  each with their directory username and password (the bank VPN asks for MFA)"
}

mailpit_on() { [ "$(jq -r '.MAILPIT // empty' .env.vault/stack.json)" = on ]; }

wave_observability() {
  local services=observability
  mailpit_on && services="$services mailpit"
  stack up $services || die "observability didn't start (above): scripts/stack.sh logs observability"
  local location ready
  leads_here grafana
  location=$(ccurl -o /dev/null -w '%{redirect_url}' "$(console grafana)/login/generic_oauth")
  case $location in
    "$(console keycloak)/realms/people/protocol/openid-connect/auth?"*) ;;
    *) die "Grafana's sign-in goes to \"$location\", not realm people at $(console keycloak): check its GF_AUTH_* in docker-compose.yml" ;;
  esac
  say "Grafana's sign-in sends the browser to realm people at $(console keycloak)."
  for ready in 9090/-/ready 3100/ready 3200/ready; do
    scripts/stack.sh exec -T observability curl -sf "http://127.0.0.1:$ready" < /dev/null > /dev/null \
      || die "Grafana's datasource on port ${ready%%/*} isn't ready: scripts/stack.sh logs observability"
  done
  say "Its datasources answer: Prometheus, Loki, Tempo."
  if mailpit_on; then
    leads_here mailpit
    ccurl -f "$(console mailpit)/api/v1/info" > /dev/null || die "Mailpit doesn't answer at $(console mailpit) with heeyID's certificate"
    say "Mailpit answers at $(console mailpit)."
  fi
}
access_observability() {
  say "  Grafana         $(console grafana): through Keycloak, with the directory username and password."
  say "                  Admins: $(group LDAP_ADMINS_GROUP_DN); Viewers: $(group LDAP_VIEWERS_GROUP_DN);"
  say "                  nobody else"
  ! mailpit_on || say "  Mailpit         $(console mailpit): heeyID's alerts, no sign-in"
}

SERVICES="myid-adapter sms-adapter taf-adapter push-adapter"
wave_services() {
  stack up $SERVICES || die "a service didn't become healthy (above): scripts/stack.sh logs <service>"
  local service tries
  for service in $SERVICES; do
    tries=0
    until scripts/stack.sh exec -T observability curl -sG http://127.0.0.1:9090/api/v1/query \
      --data-urlencode "query=platform_health_up{service_name=\"$service\"}" < /dev/null | jq -e '.data.result | length > 0' > /dev/null; do
      tries=$((tries + 1))
      [ $tries -lt 36 ] || die "no metrics from $service in Grafana after 3 minutes: scripts/stack.sh logs $service observability"
      sleep 5
    done
    say "$service is healthy and its metrics are in Grafana."
  done
  stack up heeyid-callbacks || die "the delivery reports' door didn't start (above): scripts/stack.sh logs heeyid-callbacks"
  local address status
  address=$(env_local_value CALLBACKS_ADDRESS)
  status=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -X POST "http://$address:8080/delivery-reports/xabar/$(printf '%048d' 0)/status" || true)
  case $status in
    403) say "The delivery reports' door on $address:8080 refuses this host: it takes only the bank's ingress, for Xabar's addresses." ;;
    *) die "the delivery reports' door on $address:8080 answers this host $status, not 403: check CALLBACKS_INGRESS_ADDRESSES and XABAR_ADDRESSES (scripts/stack.sh logs heeyid-callbacks)" ;;
  esac
}
access_services() {
  say "  Services        $SERVICES: no sign-in. Grafana, folder heeyid, heeyID · availability"
  say "                  shows them up, whether MyID answers, the MyID breaker, the SMS vendors' breakers, the TAF breaker and the FCM breaker"
  say "  Xabar's reports the bank's ingress passes https://<its public name>/delivery-reports/ to"
  say "                  http://$(env_local_value CALLBACKS_ADDRESS):8080 (with X-Forwarded-For); give Xabar the partner URL"
  say "                  https://<its public name>/delivery-reports/xabar/<secret>, the secret from a root token:"
  say "                  v kv get -field=XABAR_CALLBACK_SECRET secret/env/sms-adapter"
}

access_list() {
  local wave
  mkdir -p .install
  { printf 'heeyID, from a device that resolves the consoles'"'"' names to %s (written %s by scripts/install.sh)\n' "$(consoles)" "$(date -u +%FT%TZ)"
    for wave in $WAVES; do "access_$wave"; done
  } > "$ACCESS_LIST"
  step "How to get in (kept in $ACCESS_LIST)"
  cat "$ACCESS_LIST"
  cat << EOF

After a reboot: scripts/install.sh (it unseals and starts what's needed). Health any time: scripts/install.sh check
EOF
}

install() {
  [ $# -eq 0 ] || { [ "$1" = --answers ] && [ $# -eq 2 ] || die "usage: scripts/install.sh [--answers <file>]"; answers_file "$2"; }
  preflight
  env_local # on every run: a value missing now (a new setting) is asked before any wave needs it
  wave host "1. The host"
  if confirmed vault; then
    step "Vault (confirmed earlier): unsealed and a root token for this run"
    scripts/stack.sh vault-up < /dev/null
    initialized \
      || die "Vault is new, but $PROGRESS has it confirmed: a clean start removes .install too (docs/vault.md, \"Clean start\"), then run it again"
    vault_open
  fi
  wave vault "2. Vault"
  wave postgres "3. Postgres"
  wave valkey "4. Valkey"
  wave keycloak "5. Keycloak"
  wave observability "6. Grafana and observability"
  wave services "7. The adapters"
  step "The whole stack"
  stack up || die "the stack didn't come up whole (above)"
  check
  step "Closing the root-token session"
  close_session
  access_list
}

table() {
  jq -r 'def example: if . == "(empty)" then "empty" elif test(" ") then gsub("<"; "&lt;") else "`\(.)`" end;
    "| Key | What | Example (⏎: Enter takes it) |", "|---|---|---|",
    (.[] | [("`\(.name)`" + (if .file then " (`\(.file)`)" else "" end) + (if .secret then " 🔒" else "" end)),
            .what, ((.example | example) + (if .suggested then " ⏎" else "" end))] | map(gsub("\\|"; "\\|")) | "| " + join(" | ") + " |")' "$1"
}

with_table() {
  local begin="<!-- $2: scripts/install.sh docs writes this table from $1 -->" end="<!-- /$2 -->"
  case $3 in *"$begin"*"$end"*) ;; *) die "docs/settings.md lacks the $2 table's markers" ;; esac
  printf '%s\n' "$3" | T=$(table "$1") awk -v b="$begin" -v e="$end" '$0 == b { print; print ENVIRON["T"]; skip = 1; next } $0 == e { skip = 0 } !skip'
}

docs() {
  local new
  new=$(with_table "$INPUTS" inputs "$(cat docs/settings.md)")
  local both
  both=$(jq -r '.[] | select(.suggested and .empty) | .name' "$INPUTS")
  [ -z "$both" ] || die "suggested and empty both: $both (scripts/inputs.json): Enter would mean two things"
  local listed used
  listed=$(jq -r '.[] | select(.file == null) | .name' "$INPUTS" | sort)
  used=$(grep -ho 'input\["[A-Z_]*"\]' vault/tofu/*.tf | sed 's/input\["\(.*\)"\]/\1/' | sort -u)
  [ "$listed" = "$used" ] || die "scripts/inputs.json and vault/tofu disagree: $(diff <(printf '%s\n' "$listed") <(printf '%s\n' "$used") | grep '^[<>]' | tr '\n' ' ')(< the list only, > vault/tofu only)"
  if [ "${1:-}" = --check ]; then
    [ "$new" = "$(cat docs/settings.md)" ] || die "docs/settings.md's table is not $INPUTS's: scripts/install.sh docs"
    say "docs/settings.md's table is $INPUTS's; vault/tofu reads exactly $INPUTS's Vault inputs."
  else
    printf '%s\n' "$new" > docs/settings.md
    say "docs/settings.md's table written from $INPUTS."
  fi
}

case "${1:-}" in
  check) check ;;
  docs) shift; docs "$@" ;;
  *) install "$@" ;;
esac
