# Lists the certificates heeyID's CA issued and reads each (public certificates only, never a key),
# for scripts/stack.sh's list of what expires when (observability/cert-watch.sh). Only the operator's
# short render token gets it (helpers' apply).
path "pki/certs" {
  capabilities = ["list"]
}

path "pki/cert/*" {
  capabilities = ["read"]
}
