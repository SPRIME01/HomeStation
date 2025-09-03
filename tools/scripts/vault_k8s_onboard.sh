#!/usr/bin/env bash
set -euo pipefail

NAMESPACE_INFRA=${NAMESPACE_INFRA:-infra}
# Requires: VAULT_ADDR=http://127.0.0.1:8200 and VAULT_TOKEN set (port-forward is started by sso-bootstrap).

# Default to local port-forward address if not provided
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

# Fast fail if no usable Vault token
if ! vault token lookup >/dev/null 2>&1; then
  echo "ERROR: VAULT_TOKEN invalid or not set. Source tools/secrets/.envrc.vault or run 'just vault-init', then re-run 'just sso-bootstrap'."
  exit 1
fi

# Enable Kubernetes auth if not present
if ! vault auth list 2>/dev/null | grep -q '^kubernetes/'; then
  vault auth enable kubernetes >/dev/null
fi

# Ensure SA 'vault' exists in infra and has auth-delegator rights for TokenReview
kubectl -n "$NAMESPACE_INFRA" get sa vault >/dev/null 2>&1 || kubectl -n "$NAMESPACE_INFRA" create sa vault >/dev/null 2>&1
kubectl get clusterrolebinding vault-tokenreview >/dev/null 2>&1 || \
  kubectl create clusterrolebinding vault-tokenreview --clusterrole=system:auth-delegator --serviceaccount="$NAMESPACE_INFRA":vault >/dev/null 2>&1

# Try to locate a legacy token Secret bound to SA 'vault'; if absent, create a projected token Secret
SA_NAME=$(kubectl -n "$NAMESPACE_INFRA" get sa vault -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
if [ -z "$SA_NAME" ]; then
  echo "[info] No legacy ServiceAccount token found for SA 'vault' in namespace '$NAMESPACE_INFRA'. Creating a projected token Secret..."
  kubectl -n "$NAMESPACE_INFRA" apply -f - <<'EOF' >/dev/null 2>&1
apiVersion: v1
kind: Secret
metadata:
  name: vault-sa-token
  annotations:
    kubernetes.io/service-account.name: vault
type: kubernetes.io/service-account-token
EOF
  # Wait briefly for controller to populate the token
  for i in $(seq 1 15); do
    token=$(kubectl -n "$NAMESPACE_INFRA" get secret vault-sa-token -o jsonpath='{.data.token}' 2>/dev/null || true)
    if [ -n "$token" ]; then SA_NAME=vault-sa-token; break; fi
    sleep 1
  done
  if [ -z "$SA_NAME" ]; then
    echo "[error] Failed to obtain a ServiceAccount token for 'vault' in namespace '$NAMESPACE_INFRA'."
    echo "       Ensure the SA exists and the controller can create tokens, then re-run."
    exit 1
  fi
fi

SA_TOKEN=$(kubectl -n "$NAMESPACE_INFRA" get secret "$SA_NAME" -o jsonpath='{.data.token}' | base64 -d)
# Always use the in-cluster API endpoint for Vault (reachable from pods)
KUBE_HOST="https://kubernetes.default.svc:443"
KUBE_CA=$(kubectl -n "$NAMESPACE_INFRA" get secret "$SA_NAME" -o jsonpath='{.data.ca\.crt}' | base64 -d)
ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p' || true)
[ -z "$ISSUER" ] && ISSUER="https://kubernetes.default.svc.cluster.local"

if [ -n "$ISSUER" ]; then
  vault write auth/kubernetes/config token_reviewer_jwt="$SA_TOKEN" kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA" issuer="$ISSUER" >/dev/null
else
  vault write auth/kubernetes/config token_reviewer_jwt="$SA_TOKEN" kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA" >/dev/null
fi

# Read policy for ESO (kv v2 under mount "kv")
vault policy write eso-reader - <<'EOF'
path "kv/data/apps/*" {
  capabilities = ["read"]
}
path "kv/metadata/apps/*" {
  capabilities = ["read", "list"]
}
EOF

# Bind role to the External Secrets Operator controller's ServiceAccount
# Try 'audiences' first (preferred), then fallback to 'bound_audiences' for older plugins
if ! vault write auth/kubernetes/role/eso \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="$NAMESPACE_INFRA" \
  audiences="api,https://kubernetes.default.svc.cluster.local" \
  policies=eso-reader \
  ttl=24h >/dev/null 2>/tmp/vault_role_err; then
  if grep -qiE 'invalid|unknown|unsupported' /tmp/vault_role_err; then
    vault write auth/kubernetes/role/eso \
      bound_service_account_names="external-secrets" \
      bound_service_account_namespaces="$NAMESPACE_INFRA" \
      bound_audiences="api,https://kubernetes.default.svc.cluster.local" \
      policies=eso-reader \
      ttl=24h >/dev/null
  else
    echo "[error] Failed to configure role 'eso':" >&2
    cat /tmp/vault_role_err >&2 || true
    exit 1
  fi
fi

echo "[vault] Kubernetes auth configured and role 'eso' bound to SA $NAMESPACE_INFRA/external-secrets."

# Ensure a KV v2 secrets engine is enabled at path "kv" (expected by manifests and tooling)
if ! vault secrets list 2>/dev/null | awk '{print $1}' | grep -q '^kv/'; then
  echo "[vault] Enabling KV v2 secrets engine at path 'kv'"
  vault secrets enable -path=kv kv-v2 >/dev/null
else
  # If mount exists but is v1, upgrade to v2 (idempotent)
  if ! vault read kv/config >/dev/null 2>&1; then
    echo "[vault] KV mount 'kv' detected; enabling versioning (v2)"
    vault kv enable-versioning -mount=kv >/dev/null
  fi
fi
echo "[vault] KV mount ready at 'kv/'"

# Verify Kubernetes auth by performing a login with the ESO controller SA (best-effort)
if command -v kubectl >/dev/null 2>&1; then
  JWT=""
  if kubectl -n "$NAMESPACE_INFRA" get sa external-secrets >/dev/null 2>&1; then
    # Requires Kubernetes >=1.24
    JWT=$(kubectl -n "$NAMESPACE_INFRA" create token external-secrets 2>/dev/null || true)
  fi
  if [ -n "$JWT" ]; then
    if vault write -format=json auth/kubernetes/login role=eso jwt="$JWT" >/dev/null 2>&1; then
      echo "[vault] Kubernetes auth login test (role=eso, SA=$NAMESPACE_INFRA/external-secrets) succeeded"
    else
      echo "[warn] Vault Kubernetes auth login test failed for SA $NAMESPACE_INFRA/external-secrets. Check role bindings and JWT reviewer config."
    fi
  else
    echo "[info] Skipping Kubernetes auth login test (kubectl create token unsupported or SA missing)"
  fi
fi
