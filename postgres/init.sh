#!/bin/sh
# postgres-init's entrypoint: init.sql with every user's password from the environment (rendered from
# Vault, secret/env/postgres). A missing one stops it here, by name.
set -eu
export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
exec psql -h postgres -U heeyid_admin -d heeyid -f /sql/init.sql \
  -v keycloak_password="${KEYCLOAK_DB_PASSWORD:?KEYCLOAK_DB_PASSWORD is required}"
