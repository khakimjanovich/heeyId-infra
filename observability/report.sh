# shellcheck shell=bash
# report <service> <INFO|WARN> <line>: one log line to this container's collector, which keeps it in
# Loki (where the alerts look) and ships it with every other line. Sourced by the watches.
report() {
  local body
  body=$(printf '%s' "$3" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -s -o /dev/null -H 'Content-Type: application/json' http://127.0.0.1:4318/v1/logs -d \
    "{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"$1\"}}]},\"scopeLogs\":[{\"logRecords\":[{\"severityText\":\"$2\",\"body\":{\"stringValue\":\"$body\"}}]}]}]}"
  echo "$1: $3"
}
