#!/usr/bin/env bash
set -euo pipefail
# Requires: VAULT_ADDR=http://127.0.0.1:8200 and VAULT_TOKEN set (port-forward is started by sso-bootstrap).

if ! vault auth list 2>/dev/null | grep -q kubernetes; then
  vault auth enable kubernetes || true
fi

SA_NAME=$(kubectl -n infra get sa vault -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
if [ -z "$SA_NAME" ]; then
  echo "Vault ServiceAccount secret not found in 'infra' namespace. Ensure Vault chart deployed."
  exit 0
fi

SA_TOKEN=$(kubectl -n infra get secret "$SA_NAME" -o jsonpath='{.data.token}' | base64 -d)
KUBE_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
KUBE_CA=$(kubectl -n infra get secret "$SA_NAME" -o jsonpath='{.data.ca\.crt}' | base64 -d)

vault write auth/kubernetes/config token_reviewer_jwt="$SA_TOKEN" kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA" >/dev/null || true

vault policy write eso-reader - <<EOF
path "kv/data/apps/*" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/eso   bound_service_account_names=default   bound_service_account_namespaces="core,infra,observability,sso"   policies=eso-reader   ttl=24h >/dev/null || true

echo "Vault k8s auth & ESO role configured."
