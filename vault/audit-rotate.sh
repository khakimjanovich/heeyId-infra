#!/bin/sh
# vault-audit-rotate's entrypoint: Vault's audit file is moved aside once it reaches VAULT_AUDIT_MAX_MB,
# then Vault is told to reopen it (SIGHUP to process 1 of the shared process namespace: the server
# itself, never a CLI session someone runs in its container). Vault writes on to
# the moved file until it reopens, so no line is lost; the collector reads both (otelcol-heeyid.yaml).
# The newest VAULT_AUDIT_KEEP moved files stay on the volume (the bank's SIEM keeps the
# year). A missing value stops it here, by name.
set -eu
max=$((${VAULT_AUDIT_MAX_MB:?VAULT_AUDIT_MAX_MB is required} * 1024 * 1024))
keep=${VAULT_AUDIT_KEEP:?VAULT_AUDIT_KEEP is required}
log=/vault/logs/audit.log
while :; do
  if [ -f "$log" ] && [ "$(stat -c %s "$log")" -ge "$max" ]; then
    mv "$log" "$log.$(date -u +%Y%m%dT%H%M%SZ)"
    kill -HUP 1
    # shellcheck disable=SC2012 # the names are ours: audit.log.<UTC time>
    ls -1t "$log".* | tail -n +$((keep + 1)) | xargs -r rm -f
    echo "vault-audit-rotate: rotated at $max bytes"
  fi
  sleep 30
done
