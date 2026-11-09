#!/bin/sh
# Mailpit's entrypoint: its web console's certificate from heeyID's CA (rendered from Vault,
# secret/env/mailpit) into files only this process reads, then Mailpit serving HTTPS. A missing value
# stops it here, by name.
set -eu
umask 077
mkdir -p /tmp/tls
printf '%s\n' "${MAILPIT_TLS_CERTIFICATE:?MAILPIT_TLS_CERTIFICATE is required}" > /tmp/tls/server.pem
printf '%s\n' "${MAILPIT_TLS_PRIVATE_KEY:?MAILPIT_TLS_PRIVATE_KEY is required}" > /tmp/tls/server-key.pem
exec /mailpit # MP_UI_TLS_CERT and MP_UI_TLS_KEY (docker-compose.yml) name the two files
