#!/bin/bash
# The certificate watch, daily, run by observability/start.sh: every certificate heeyID serves or
# trusts, from the list scripts/stack.sh writes at each `up` (the services', the consoles', the CAs
# they trust, and every live one heeyID's CA issued). One line per certificate within CERT_ALERT_DAYS
# of its end (cert_expiring), and one per run (cert_watch_ran); the alerts mail the first, and the
# absence of the second (observability/alerting/rules.yaml).
set -uo pipefail
# shellcheck source=observability/report.sh
. /heeyid/report.sh
days=${CERT_ALERT_DAYS:?CERT_ALERT_DAYS is required}
list=/heeyid/cert-expiry.txt

watch() {
  # No list (or an empty one) is a watch that can't watch: say so, and write no cert_watch_ran, so
  # "Certificate watch stopped" fires.
  if [ ! -s "$list" ]; then
    report cert-watch WARN "cert_watch_failed: no certificate list at $list (scripts/stack.sh up writes it)"
    return
  fi
  local -A ends=()
  local end name epoch left soonest="" soonest_left=""
  # "<openssl's notAfter>|<name>"; a certificate renewed keeps its name: only its latest end counts.
  while IFS='|' read -r end name; do
    [ -n "$name" ] || continue
    epoch=$(date -d "$end" +%s 2> /dev/null) || { report cert-watch WARN "cert_expiring: $name has an unreadable end date ($end)"; continue; }
    [ -z "${ends[$name]:-}" ] || [ "$epoch" -gt "${ends[$name]}" ] && ends[$name]=$epoch
  done < "$list"
  for name in "${!ends[@]}"; do
    left=$(( (ends[$name] - $(date +%s)) / 86400 ))
    if [ "$left" -le "$days" ]; then
      report cert-watch WARN "cert_expiring: $name ends in $left days ($(date -u -d "@${ends[$name]}" +%F))"
    fi
    if [ -z "$soonest_left" ] || [ "$left" -lt "$soonest_left" ]; then soonest=$name; soonest_left=$left; fi
  done
  report cert-watch INFO "cert_watch_ran: ${#ends[@]} certificates, the nearest $soonest in $soonest_left days"
}

sleep 60 # the stack comes up first
while :; do
  watch
  sleep 86400
done
