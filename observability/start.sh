#!/bin/bash
# observability's entrypoint, from its settings (rendered from Vault, secret/env/observability):
#   - Grafana's certificate from heeyID's CA into files only this process can read: Grafana serves
#     HTTPS only;
#   - the collector's additions (otelcol-heeyid.yaml) and what goes to the bank's observability, each
#     kind only when its setting names a collector, which must answer now: every log line
#     (LOG_SHIP_PROTOCOL otlp or syslog), the metrics (METRICS_SHIP_ENDPOINT) and the traces
#     (TRACES_SHIP_ENDPOINT), over TLS checked against SHIP_TRUSTED_CAS, with SHIP_AUTHORIZATION as the
#     OTLP calls' Authorization header when the bank gives one. Everything stays in this stack too;
#   - the certificate watch in the background;
#   - then the image's own start.
# A missing or wrong value stops it here, by name.
set -euo pipefail
umask 077
mkdir -p /tmp/tls
printf '%s\n' "${GRAFANA_TLS_CERTIFICATE:?GRAFANA_TLS_CERTIFICATE is required}" > /tmp/tls/server.pem
printf '%s\n' "${GRAFANA_TLS_PRIVATE_KEY:?GRAFANA_TLS_PRIVATE_KEY is required}" > /tmp/tls/server-key.pem
# The CA of Keycloak's certificate, for the sign-in's token and userinfo calls.
printf '%s\n' "${GRAFANA_TRUSTED_CAS:?GRAFANA_TRUSTED_CAS is required}" > /tmp/tls/ca.pem

# Each collector of the bank must be reachable now: a stack that can't ship what it was told to
# doesn't start.
answers() { # <what> <host:port>
  timeout 5 bash -c "exec 3<>/dev/tcp/${2%:*}/${2##*:}" 2> /dev/null \
    || { echo "observability: the bank's $1 collector $2 doesn't answer: check its setting and the route to it" >&2; exit 1; }
}
host_port() { local a=${1#https://}; printf '%s' "${a%%/*}"; }
extra="--config=file:/heeyid/otelcol-heeyid.yaml"
shipping=no
case ${LOG_SHIP_PROTOCOL:?LOG_SHIP_PROTOCOL is required} in
  otlp) answers log "$(host_port "${LOG_SHIP_ENDPOINT:?LOG_SHIP_ENDPOINT is required}")"
    extra="$extra --config=file:/heeyid/otelcol-ship-otlp.yaml"; shipping=yes ;;
  syslog) address=${LOG_SHIP_ENDPOINT:?LOG_SHIP_ENDPOINT is required}; answers log "$address"
    export LOG_SHIP_HOST=${address%:*} LOG_SHIP_PORT=${address##*:}
    extra="$extra --config=file:/heeyid/otelcol-ship-syslog.yaml"; shipping=yes ;;
  off) echo "observability: LOG_SHIP_PROTOCOL=off: the log lines stay in this stack" ;;
  *) echo "observability: LOG_SHIP_PROTOCOL must be otlp, syslog or off, not $LOG_SHIP_PROTOCOL" >&2; exit 1 ;;
esac
otlp_exporters=""
[ "$LOG_SHIP_PROTOCOL" != otlp ] || otlp_exporters="otlp_http/ship"
for kind in metrics traces; do
  name=$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')_SHIP_ENDPOINT
  endpoint=${!name?$name is required (empty: not shipped)}
  if [ -n "$endpoint" ]; then
    answers "$kind" "$(host_port "$endpoint")"
    extra="$extra --config=file:/heeyid/otelcol-ship-$kind.yaml"; shipping=yes
    otlp_exporters="$otlp_exporters otlp_http/ship-$kind"
    echo "observability: shipping the $kind to $endpoint"
  else
    echo "observability: ${name}=: the $kind stay in this stack"
  fi
done
if [ "$shipping" = yes ]; then
  printf '%s\n' "${SHIP_TRUSTED_CAS:?SHIP_TRUSTED_CAS is required}" > /tmp/tls/ship-ca.pem
  # The bank's Authorization header for every OTLP exporter, only when it gives one: merged over
  # their files, the header's value read from the environment, never written to a file.
  if [ -n "${SHIP_AUTHORIZATION?SHIP_AUTHORIZATION is required (empty: none)}" ] && [ -n "$otlp_exporters" ]; then
    export SHIP_AUTHORIZATION
    { echo "exporters:"
      for exporter in $otlp_exporters; do
        printf '  %s:\n    headers:\n      Authorization: ${env:SHIP_AUTHORIZATION}\n' "$exporter"
      done; } > /tmp/otelcol-ship-authorization.yaml
    extra="$extra --config=file:/tmp/otelcol-ship-authorization.yaml"
  fi
  [ "$LOG_SHIP_PROTOCOL" = off ] || echo "observability: shipping every log line ($LOG_SHIP_PROTOCOL)"
fi
export OTELCOL_EXTRA_ARGS=$extra

# The certificate watch: daily, over scripts/stack.sh's list (observability/cert-watch.sh).
: "${CERT_ALERT_DAYS:?CERT_ALERT_DAYS is required}"
/bin/bash /heeyid/cert-watch.sh &

# The image's start script waits for Grafana's health on plain HTTP, which never answers here (Grafana
# serves HTTPS only): a copy of it waits on HTTPS instead, the image untouched. An image without
# that line stops here.
cd /otel-lgtm
# shellcheck disable=SC2016 # ${url} is the script's own text, not this shell's
sed -e 's|services\["grafana"\]="http://127.0.0.1:3000/api/health"|services["grafana"]="https://127.0.0.1:3000/api/health"|' \
  -e 's|curl -o /dev/null -sg "${url}"|curl -k -o /dev/null -sg "${url}"|' run-all.sh > /tmp/run-all.sh
if ! grep -q 'services\["grafana"\]="https://' /tmp/run-all.sh || ! grep -q 'curl -k -o /dev/null -sg' /tmp/run-all.sh; then
  echo "observability/start.sh: run-all.sh no longer has the lines it rewrites; check this image version" >&2
  exit 1
fi
exec /bin/bash /tmp/run-all.sh
