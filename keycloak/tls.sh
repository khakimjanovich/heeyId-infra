#!/bin/bash
set -euo pipefail
umask 077
mkdir -p /tmp/tls
printf '%s\n' "${KEYCLOAK_TLS_CERTIFICATE:?KEYCLOAK_TLS_CERTIFICATE is required}" > /tmp/tls/server.pem
printf '%s\n' "${KEYCLOAK_TLS_PRIVATE_KEY:?KEYCLOAK_TLS_PRIVATE_KEY is required}" > /tmp/tls/server-key.pem
printf '%s\n' "${LDAP_TRUSTED_CAS:?LDAP_TRUSTED_CAS is required}" > /tmp/tls/directory-ca.pem
exec /opt/keycloak/bin/kc.sh "$@"
