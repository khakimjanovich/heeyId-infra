#!/bin/sh
# postgres-init's entrypoint: init.sql with every user's password from the environment (rendered from
# Vault, secret/env/postgres). A missing one stops it here, by name.
set -eu
export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
exec psql -h postgres -U heeyid_admin -d heeyid -f /sql/init.sql \
  -v modules="access customer grants antifraud notification catalogue staff audit" \
  -v keycloak_password="${KEYCLOAK_DB_PASSWORD:?KEYCLOAK_DB_PASSWORD is required}" \
  -v access_password="${HEEYID_DB_ACCESS_PASSWORD:?HEEYID_DB_ACCESS_PASSWORD is required}" \
  -v customer_password="${HEEYID_DB_CUSTOMER_PASSWORD:?HEEYID_DB_CUSTOMER_PASSWORD is required}" \
  -v grants_password="${HEEYID_DB_GRANTS_PASSWORD:?HEEYID_DB_GRANTS_PASSWORD is required}" \
  -v antifraud_password="${HEEYID_DB_ANTIFRAUD_PASSWORD:?HEEYID_DB_ANTIFRAUD_PASSWORD is required}" \
  -v notification_password="${HEEYID_DB_NOTIFICATION_PASSWORD:?HEEYID_DB_NOTIFICATION_PASSWORD is required}" \
  -v catalogue_password="${HEEYID_DB_CATALOGUE_PASSWORD:?HEEYID_DB_CATALOGUE_PASSWORD is required}" \
  -v staff_password="${HEEYID_DB_STAFF_PASSWORD:?HEEYID_DB_STAFF_PASSWORD is required}" \
  -v audit_password="${HEEYID_DB_AUDIT_PASSWORD:?HEEYID_DB_AUDIT_PASSWORD is required}" \
  -v viewer_password="${HEEYID_DB_VIEWER_PASSWORD:?HEEYID_DB_VIEWER_PASSWORD is required}"
