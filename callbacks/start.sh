#!/bin/sh
# heeyid-callbacks' entrypoint: writes who may reach the door (callbacks/nginx.conf) from its settings,
# rendered from Vault (secret/env/callbacks), then starts nginx. Each list: IPv4 addresses or networks,
# comma separated. A missing value stops it here, by name.
set -eu
ingress=${CALLBACKS_INGRESS_ADDRESSES:?CALLBACKS_INGRESS_ADDRESSES is required}
xabar=${XABAR_ADDRESSES:?XABAR_ADDRESSES is required}
each() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d'; }
mkdir -p /tmp/callbacks
{
  each "$ingress" | sed 's/.*/set_real_ip_from &;/'
  echo 'geo $realip_remote_addr $from_ingress {'
  echo '  default 0;'
  each "$ingress" | sed 's/.*/  & 1;/'
  echo '}'
  echo 'geo $remote_addr $from_xabar {'
  echo '  default 0;'
  each "$xabar" | sed 's/.*/  & 1;/'
  echo '}'
} > /tmp/callbacks/addresses.conf
exec nginx -g 'daemon off;'
