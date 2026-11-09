#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit # a failing command inside $(...) stops it too
kcadm=/opt/keycloak/bin/kcadm.sh
json() { local v=$1; v=${v//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
client_secret() { printf '{"secret":%s}' "$(json "$3")" | $kcadm update "clients/$2" -r "$1" -f -; }
export KC_CLI_CONFIG=/tmp/kcadm.config
printf '%s\n' "${KEYCLOAK_TRUSTED_CAS:?KEYCLOAK_TRUSTED_CAS is required}" > /tmp/heeyid-ca.pem
rm -f /tmp/heeyid-ca.p12
keytool -importcert -noprompt -alias heeyid-ca -file /tmp/heeyid-ca.pem -keystore /tmp/heeyid-ca.p12 \
  -storetype PKCS12 -storepass heeyid-ca > /dev/null
$kcadm config truststore --trustpass heeyid-ca /tmp/heeyid-ca.p12
server=https://heeyid-keycloak:8443
config_secret=${KEYCLOAK_CONFIG_CLIENT_SECRET:?KEYCLOAK_CONFIG_CLIENT_SECRET is required}
as_client() { $kcadm config credentials --server "$server" --realm master --client heeyid-config --secret "$config_secret" > /dev/null 2>&1; }
if ! as_client; then
  $kcadm config credentials --server "$server" --realm master --user admin \
    --password "${KC_BOOTSTRAP_ADMIN_PASSWORD:?KC_BOOTSTRAP_ADMIN_PASSWORD is required}" > /dev/null \
    || { echo "keycloak-config: neither client heeyid-config nor the bootstrap admin can sign in to realm master" >&2; exit 1; }
  id=$($kcadm get clients -r master -q clientId=heeyid-config --fields id --format csv --noquotes)
  if [ -z "$id" ]; then
    printf '{"clientId":"heeyid-config","description":"keycloak-config","enabled":true,"publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":true,"secret":"%s"}' \
      "$config_secret" | $kcadm create clients -r master -f - > /dev/null
    $kcadm add-roles -r master --uusername service-account-heeyid-config --rolename admin
  else
    client_secret master "$id" "$config_secret"
  fi
  as_client || { echo "keycloak-config: client heeyid-config can't sign in" >&2; exit 1; }
  echo "keycloak-config: client heeyid-config made"
fi
$kcadm create partialImport -r services -s ifResourceExists=OVERWRITE -o -f /services-realm.json > /dev/null
secret() {
  id=$($kcadm get clients -r services -q "clientId=$1" --fields id --format csv --noquotes)
  [ -n "$id" ] || { echo "keycloak-config: client $1 is missing in realm services" >&2; exit 1; }
  client_secret services "$id" "$2"
}
# heeyID's own callers of the MyID adapter (vault/tofu, local.callers): each client's secret, generated
# by OpenTofu; their role and audience come from services-realm.json.
for caller in $(printf '%s' "${MYID_ADAPTER_CALLERS:?MYID_ADAPTER_CALLERS is required}" | tr ',' ' '); do
  name=$(printf '%s' "$caller" | tr '[:lower:]-' '[:upper:]_')_CLIENT_SECRET
  secret "$caller" "${!name:?$name is required}"
done
echo "keycloak-config: realm services configured"

failures=${CONSOLE_LOCKOUT_FAILURES:?CONSOLE_LOCKOUT_FAILURES is required}
lockout=$((${CONSOLE_LOCKOUT_MINUTES:?CONSOLE_LOCKOUT_MINUTES is required} * 60))
idle=$((${CONSOLE_IDLE_MINUTES:?CONSOLE_IDLE_MINUTES is required} * 60))
rules() {
  $kcadm update "realms/$1" -s 'passwordPolicy=' -s bruteForceProtected=true -s permanentLockout=false -s "failureFactor=$failures" \
    -s "waitIncrementSeconds=$lockout" -s "maxFailureWaitSeconds=$lockout" -s maxDeltaTimeSeconds=43200 \
    -s "ssoSessionIdleTimeout=$idle" -s "ssoSessionMaxLifespan=36000"
  for flow in browser direct%20grant; do
    for row in $($kcadm get "authentication/flows/$flow/executions" -r "$1" --fields id,priority,displayName --format csv --noquotes | tr ' ' '_'); do
      IFS=, read -r id priority name <<< "$row"
      case $name in Browser_-_Conditional_2FA | Direct_Grant_-_Conditional_OTP)
        $kcadm update "authentication/flows/$flow/executions" -r "$1" -b "{\"id\":\"$id\",\"requirement\":\"CONDITIONAL\",\"priority\":$priority}" ;;
      esac
    done
  done
}
filtered() { local v=$1; v=${v//\\/\\5c}; v=${v//\*/\\2a}; v=${v//(/\\28}; v=${v//)/\\29}; printf '%s' "$v"; }
ldap_url=${LDAP_URL:?LDAP_URL is required}
bind_dn=${LDAP_BIND_DN:?LDAP_BIND_DN is required}
admins_group=$(filtered "${LDAP_ADMINS_GROUP_DN:?LDAP_ADMINS_GROUP_DN is required}")
viewers_group=$(filtered "${LDAP_VIEWERS_GROUP_DN:?LDAP_VIEWERS_GROUP_DN is required}")
: "${LDAP_BIND_PASSWORD:?LDAP_BIND_PASSWORD is required}" "${LDAP_VENDOR:?LDAP_VENDOR is required}" \
  "${LDAP_USERS_DN:?LDAP_USERS_DN is required}" "${LDAP_USER_OBJECT_CLASSES:?LDAP_USER_OBJECT_CLASSES is required}" \
  "${LDAP_USERNAME_ATTRIBUTE:?LDAP_USERNAME_ATTRIBUTE is required}" "${LDAP_UUID_ATTRIBUTE:?LDAP_UUID_ATTRIBUTE is required}"

directory=reachable
printf '{"action":"testAuthentication","connectionUrl":%s,"authType":"simple","bindDn":%s,"bindCredential":%s,"useTruststoreSpi":"always","connectionTimeout":"10000"}' \
  "$(json "$ldap_url")" "$(json "$bind_dn")" "$(json "$LDAP_BIND_PASSWORD")" \
  | $kcadm create testLDAPConnection -r master -f - > /dev/null 2>&1 || directory=unreachable
if [ "$directory" = unreachable ]; then
  [ -n "$($kcadm get components -r master -q type=org.keycloak.storage.UserStorageProvider -q name=directory --fields id --format csv --noquotes)" ] \
    || { echo "keycloak-config: Keycloak can't sign in to the directory $ldap_url as $bind_dn: check LDAP_URL, LDAP_TRUSTED_CAS, LDAP_BIND_DN and LDAP_BIND_PASSWORD; the bootstrap admin stays until it can" >&2; exit 1; }
  echo "keycloak-config: the directory $ldap_url doesn't answer now: its people stay as they were set up, everything else goes on" >&2
fi

federation() {
  local realm_id id body
  realm_id=$($kcadm get "realms/$1" --fields id --format csv --noquotes)
  body=$(printf '{"name":"directory","providerId":"ldap","providerType":"org.keycloak.storage.UserStorageProvider","parentId":%s,"config":{"enabled":["true"],"priority":["0"],"vendor":[%s],"connectionUrl":[%s],"authType":["simple"],"bindDn":[%s],"bindCredential":[%s],"usersDn":[%s],"userObjectClasses":[%s],"usernameLDAPAttribute":[%s],"rdnLDAPAttribute":[%s],"uuidLDAPAttribute":[%s],"customUserSearchFilter":[%s],"searchScope":["2"],"editMode":["READ_ONLY"],"importEnabled":["true"],"syncRegistrations":["false"],"useTruststoreSpi":["always"],"connectionPooling":["true"],"pagination":["true"],"trustEmail":["false"],"validatePasswordPolicy":["false"],"cachePolicy":["NO_CACHE"]}}' \
    "$(json "$realm_id")" "$(json "$LDAP_VENDOR")" "$(json "$ldap_url")" "$(json "$bind_dn")" "$(json "$LDAP_BIND_PASSWORD")" \
    "$(json "$LDAP_USERS_DN")" "$(json "$LDAP_USER_OBJECT_CLASSES")" "$(json "$LDAP_USERNAME_ATTRIBUTE")" \
    "$(json "$LDAP_USERNAME_ATTRIBUTE")" "$(json "$LDAP_UUID_ATTRIBUTE")" "$(json "$2")")
  id=$($kcadm get components -r "$1" -q type=org.keycloak.storage.UserStorageProvider -q name=directory --fields id --format csv --noquotes)
  if [ -z "$id" ]; then
    printf '%s' "$body" | $kcadm create components -r "$1" -f - > /dev/null
    id=$($kcadm get components -r "$1" -q type=org.keycloak.storage.UserStorageProvider -q name=directory --fields id --format csv --noquotes)
  else
    printf '%s' "$body" | $kcadm update "components/$id" -r "$1" -f -
  fi
  FEDERATION=$id
}
mapper() {
  local name id
  name=$(printf '%s' "$3" | sed -n 's/^{"name":"\([^"]*\)".*/\1/p')
  id=$($kcadm get components -r "$1" -q "parent=$2" -q "name=$name" --fields id --format csv --noquotes)
  if [ -z "$id" ]; then
    printf '%s' "$3" | $kcadm create components -r "$1" -f - > /dev/null
    id=$($kcadm get components -r "$1" -q "parent=$2" -q "name=$name" --fields id --format csv --noquotes)
  else
    printf '%s' "$3" | $kcadm update "components/$id" -r "$1" -f -
  fi
  printf '%s' "$id"
}
group_role() {
  local rdn=${3%%,*} id group name
  $kcadm get "group-by-path/$5" -r "$1" > /dev/null 2>&1 || $kcadm create groups -r "$1" -s "name=$5" > /dev/null
  id=$(mapper "$1" "$2" "$(printf '{"name":%s,"providerId":"group-ldap-mapper","providerType":"org.keycloak.storage.ldap.mappers.LDAPStorageMapper","parentId":%s,"config":{"groups.dn":[%s],"group.name.ldap.attribute":[%s],"group.object.classes":["top"],"groups.ldap.filter":[%s],"preserve.group.inheritance":["false"],"ignore.missing.groups":["true"],"membership.ldap.attribute":["member"],"membership.attribute.type":["DN"],"membership.user.ldap.attribute":[%s],"memberof.ldap.attribute":["memberOf"],"user.roles.retrieve.strategy":["GET_GROUPS_FROM_USER_MEMBEROF_ATTRIBUTE"],"mode":["READ_ONLY"],"groups.path":[%s],"drop.non.existing.groups.during.sync":["false"]}}' \
    "$(json "$4")" "$(json "$2")" "$(json "${3#*,}")" "$(json "${rdn%%=*}")" "$(json "($(filtered "$rdn"))")" "$(json "$LDAP_USERNAME_ATTRIBUTE")" "$(json "/$5")")")
  $kcadm create "user-storage/$2/mappers/$id/sync?direction=fedToKeycloak" -r "$1" > /dev/null \
    || { echo "keycloak-config: the directory group $3 can't be read under its parent: check the DN" >&2; exit 1; }
  name=${rdn#*=}
  group=$($kcadm get "group-by-path/$5/${name// /%20}" -r "$1" --fields id --format csv --noquotes 2> /dev/null) \
    || { echo "keycloak-config: the directory has no group $3" >&2; exit 1; }
  $kcadm add-roles -r "$1" --gid "$group" --rolename "$4"
}
synced() {
  local out n=0 count failed
  out=$($kcadm create "user-storage/$2/sync?action=triggerFullSync" -r "$1" -o) \
    || { echo "keycloak-config: realm $1 can't read the directory's people (above)" >&2; exit 1; }
  for count in $(printf '%s\n' "$out" | sed -n 's/.*"\(added\|updated\)" *: *\([0-9]*\).*/\2/p'); do n=$((n + count)); done
  failed=$(printf '%s\n' "$out" | sed -n 's/.*"failed" *: *\([0-9]*\).*/\1/p')
  [ "${failed:-0}" -eq 0 ] || echo "keycloak-config: realm $1: $failed of the directory's people not brought in (above)" >&2
  echo "$n"
}
retire() {
  local row id name link renamed
  for row in $($kcadm get users -r "$1" -q enabled=true -q max=-1 --fields id,username,federationLink --format csv --noquotes); do
    IFS=, read -r id name link <<< "$row"
    case $name in service-account-* | "$2") continue ;; esac
    [ -z "$link" ] || continue
    case $1:$name in
      *:retired-* | master:admin) ;;
      *)
        $kcadm update "realms/$1" -s editUsernameAllowed=true
        renamed=yes
        $kcadm update "users/$id" -r "$1" -s "username=retired-$name-${id%%-*}" || renamed=no
        $kcadm update "realms/$1" -s editUsernameAllowed=false
        [ "$renamed" = yes ] || { echo "keycloak-config: $name can't be renamed in realm $1 (above)" >&2; exit 1; } ;;
    esac
    $kcadm update "users/$id" -r "$1" -s enabled=false
    echo "keycloak-config: $name disabled in realm $1 (not the directory's)"
  done
}

if ! $kcadm get realms/people > /dev/null 2>&1; then
  $kcadm create realms -s realm=people -s enabled=true > /dev/null
  as_client # a token from before the realm existed may not manage it
fi
domain=${CONSOLES_DOMAIN:?CONSOLES_DOMAIN is required}
$kcadm update realms/master -s "attributes.frontendUrl=https://keycloak.$domain"
as_client # a token from before master's frontendUrl names the old issuer, and is refused from now on
$kcadm update realms/people -s "attributes.frontendUrl=https://keycloak.$domain"
rules people
rules master
for role in console.admin console.viewer; do
  $kcadm get "roles/$role" -r people > /dev/null 2>&1 || $kcadm create roles -r people -s "name=$role" > /dev/null
done

grafana='{"clientId":"grafana","name":"Grafana","enabled":true,"publicClient":false,"standardFlowEnabled":true,"implicitFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":false,"redirectUris":["https://grafana.'$domain'/login/generic_oauth"],"webOrigins":[],"attributes":{"pkce.code.challenge.method":"S256","post.logout.redirect.uris":"https://grafana.'$domain'/login"}}'
id=$($kcadm get clients -r people -q clientId=grafana --fields id --format csv --noquotes)
if [ -z "$id" ]; then
  printf '%s' "$grafana" | $kcadm create clients -r people -f - > /dev/null
  id=$($kcadm get clients -r people -q clientId=grafana --fields id --format csv --noquotes)
  printf '{"name":"roles","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper","config":{"claim.name":"roles","multivalued":"true","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' \
    | $kcadm create "clients/$id/protocol-mappers/models" -r people -f - > /dev/null
else
  printf '%s' "$grafana" | $kcadm update "clients/$id" -r people -f -
fi
client_secret people "$id" "${GRAFANA_CLIENT_SECRET:?GRAFANA_CLIENT_SECRET is required}"

rotate_days=${KEYCLOAK_KEY_ROTATE_DAYS:?KEYCLOAK_KEY_ROTATE_DAYS is required}
signing_keys() { # realm
  local realm_id rows newest previous now id name
  now=$(date -u +%s)
  realm_id=$($kcadm get "realms/$1" --fields id --format csv --noquotes)
  rows=$($kcadm get components -r "$1" -q type=org.keycloak.keys.KeyProvider --fields id,name,providerId --format csv --noquotes | grep ',rsa-generated$' || true)
  newest=$(printf '%s\n' "$rows" | grep -o 'heeyid-rsa-[0-9]*' | sort -t- -k3 -n | tail -1 || true)
  if [ -z "$newest" ] || [ $(( (now - ${newest##*-}) / 86400 )) -ge "$rotate_days" ]; then
    $kcadm create components -r "$1" -s "name=heeyid-rsa-$now" -s providerId=rsa-generated \
      -s providerType=org.keycloak.keys.KeyProvider -s "parentId=$realm_id" -s "config.priority=[\"$now\"]" \
      -s 'config.keySize=["2048"]' -s 'config.active=["true"]' -s 'config.enabled=["true"]' > /dev/null
    rows=$($kcadm get components -r "$1" -q type=org.keycloak.keys.KeyProvider --fields id,name,providerId --format csv --noquotes | grep ',rsa-generated$')
    echo "keycloak-config: realm $1 signs with a new key, heeyid-rsa-$now"
  fi
  newest=$(printf '%s\n' "$rows" | grep -o 'heeyid-rsa-[0-9]*' | sort -t- -k3 -n | tail -1)
  previous=$(printf '%s\n' "$rows" | grep -o 'heeyid-rsa-[0-9]*' | sort -t- -k3 -n | tail -2 | head -n -1 || true)
  for row in $rows; do
    IFS=, read -r id name _ <<< "$row"
    case $name in
      "$newest") ;;
      "$previous") $kcadm update "components/$id" -r "$1" -s 'config.active=["false"]' ;;
      heeyid-rsa-*) $kcadm delete "components/$id" -r "$1" ;;
      *) if [ -n "$previous" ]; then $kcadm delete "components/$id" -r "$1"; else $kcadm update "components/$id" -r "$1" -s 'config.active=["false"]'; fi ;;
    esac
  done
}
for realm in services people master; do signing_keys "$realm"; done

people_setup() {
  federation master "(memberOf=$admins_group)"
  master_directory=$FEDERATION
  mapper master "$master_directory" "$(printf '{"name":"admin","providerId":"hardcoded-ldap-role-mapper","providerType":"org.keycloak.storage.ldap.mappers.LDAPStorageMapper","parentId":%s,"config":{"role":["admin"]}}' "$(json "$master_directory")")" > /dev/null
  federation people "(|(memberOf=$admins_group)(memberOf=$viewers_group))"
  people_directory=$FEDERATION
  retire people ""
  retire master admin
  admins=$(synced master "$master_directory")
  [ "$admins" -gt 0 ] || { echo "keycloak-config: the directory has nobody in LDAP_ADMINS_GROUP_DN under LDAP_USERS_DN (does it give people memberOf?): the bootstrap admin stays until it does" >&2; exit 1; }
  group_role people "$people_directory" "$LDAP_ADMINS_GROUP_DN" console.admin console-admins
  group_role people "$people_directory" "$LDAP_VIEWERS_GROUP_DN" console.viewer console-viewers
  people=$(synced people "$people_directory")
  retire master ""
  echo "keycloak-config: $admins admins and $people people in all from the directory; nobody else, the bootstrap admin included"
}
if [ "$directory" = reachable ]; then
  if [ -n "$($kcadm get components -r master -q type=org.keycloak.storage.UserStorageProvider -q name=directory --fields id --format csv --noquotes)" ]; then
    people_setup &
    wait $! || echo "keycloak-config: the directory's people weren't brought in line this time (above); those set up before stay" >&2
  else
    people_setup
  fi
fi
