#!/bin/sh
# valkey's entrypoint (SAD §6, "Cache"): Valkey with its append-only file synced each second, the default
# user off, and one ACL user per service, from its settings (rendered from Vault, secret/env/valkey).
# Each user reaches only keys <tenant prefix>:<its name>:* and only the commands it sends:
#   myid-adapter  each tenant's MyID tokens (GET, SET with a TTL, DEL); PING and INFO for its health
#                 check; HELLO and CLIENT SETINFO, which its client (Lettuce) sends when it connects.
# The passwords go to Valkey in an ACL file only this process reads, never on its command line.
# A missing value stops it here, by name.
set -eu
umask 077
acl=/tmp/users.acl
{
  echo "user default off"
  echo "user myid-adapter on >${VALKEY_MYID_ADAPTER_PASSWORD:?VALKEY_MYID_ADAPTER_PASSWORD is required} resetkeys ~*:myid-adapter:* resetchannels -@all +get +set +del +ping +info +hello +client|setinfo"
} > "$acl"
exec valkey-server --dir /data --appendonly yes --appendfsync everysec --aclfile "$acl" --protected-mode no
