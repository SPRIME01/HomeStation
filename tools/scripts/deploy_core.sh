#!/usr/bin/env bash
set -Eeuo pipefail

on_err() {
  local ec=${1:-1}
  local ln=${2:-}
  echo "[error] deploy_core.sh failed${ln:+ at line }${ln} (exit $ec)" >&2
}
trap 'on_err $? $LINENO' ERR

NAMESPACE_CORE=${NAMESPACE_CORE:-core}
INSTALL_DRY_RUN=${INSTALL_DRY_RUN:-0}
HELM_REGISTRY_CONFIG=${HELM_REGISTRY_CONFIG:-.helm-registry/config.json}
HELM_NO_CREDS=${HELM_NO_CREDS:-0}
RABBITMQ_CHART_VERSION=${RABBITMQ_CHART_VERSION:-16.0.14}
N8N_CHART_VERSION=${N8N_CHART_VERSION:-}

say(){ printf '%s\n' "$*"; }
run(){ if [ "$INSTALL_DRY_RUN" = "1" ]; then echo "(dry-run) $*"; else eval "$*"; fi }

# Ensure a local, minimal Helm registry config is used and contains no credential helpers
preflight_registry_cfg() {
  local cfg="$HELM_REGISTRY_CONFIG"
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  local has_credsStore has_credHelpers
  if grep -q '"credsStore"' "$cfg" 2>/dev/null; then has_credsStore=1; else has_credsStore=0; fi
  if grep -q '"credHelpers"' "$cfg" 2>/dev/null; then has_credHelpers=1; else has_credHelpers=0; fi
  echo "[helm] Using HELM_REGISTRY_CONFIG=$cfg"
  if [ "$has_credsStore" = "1" ] || [ "$has_credHelpers" = "1" ]; then
    echo "[error] HELM_REGISTRY_CONFIG contains credential helper settings (credsStore/credHelpers)." >&2
    echo "        Please remove them or set HELM_NO_CREDS=1 to isolate DOCKER_CONFIG." >&2
    echo "        File: $cfg" >&2
    exit 1
  fi
}

# Optional creds bypass
if [ "$HELM_NO_CREDS" = "1" ]; then
  mkdir -p .docker-nocreds
  [ -f .docker-nocreds/config.json ] || echo '{}' > .docker-nocreds/config.json
  export DOCKER_CONFIG="$PWD/.docker-nocreds"
  say "[info] HELM_NO_CREDS=1 using DOCKER_CONFIG=$DOCKER_CONFIG"
fi

# Print and enforce Helm registry config hygiene
preflight_registry_cfg

# Ensure target namespace exists
kubectl get ns "$NAMESPACE_CORE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_CORE" >/dev/null

# Apply RabbitMQ ExternalSecret first (so the Secret is created ASAP)
if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  # Ensure ClusterSecretStore wiring to Vault is present (idempotent)
  [ -f deploy/eso/vault-clustersecretstore.yaml ] && kubectl apply -f deploy/eso/vault-clustersecretstore.yaml || true

  # Wait for ClusterSecretStore readiness (up to 120s) for clear diagnostics
  if [ "$INSTALL_DRY_RUN" != "1" ]; then
    say "[eso] Waiting for ClusterSecretStore 'vault-kv' to be Ready (timeout 120s)"
    start_ts=$(date +%s)
    while true; do
      css_ready=$(kubectl get clustersecretstore.external-secrets.io vault-kv -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      css_msg=$(kubectl get clustersecretstore.external-secrets.io vault-kv -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
      if [ "$css_ready" = "True" ]; then break; fi
      now=$(date +%s); elapsed=$(( now - start_ts ))
      [ $elapsed -ge 120 ] && break || true
      [ -n "$css_msg" ] && say "[eso] status: $css_msg"
      sleep 3
    done
    if [ "${css_ready:-}" != "True" ]; then
      say "[error] ClusterSecretStore vault-kv not Ready."
      [ -n "${css_msg:-}" ] && say "        Reason: $css_msg"
      say "        Hints:"
      say "          - Run: just sso-bootstrap (requires VAULT_TOKEN) to onboard Vault Kubernetes auth"
      say "          - Seed KV: just vault-seed-kv --only rabbitmq --random (requires VAULT_TOKEN)"
      say "          - Logs: kubectl -n infra logs deploy/external-secrets"
      say "          - Verify SA: kubectl -n infra get sa external-secrets -o yaml"
      say "          - Verify Vault: (pf) vault read auth/kubernetes/role/eso"
      exit 1
    fi
  fi

  [ -f deploy/rabbitmq/externalsecret.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/rabbitmq/externalsecret.yaml || true
  # Wait for the Secret to be materialized by ESO to avoid Helm upgrade credential errors
  if [ "$INSTALL_DRY_RUN" != "1" ]; then
    say "[rabbitmq] Waiting for Secret 'rabbitmq-auth' to be created by External Secrets (timeout 90s)"
    start_ts=$(date +%s)
    while true; do
      if kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth >/dev/null 2>&1; then
        pw=$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null || true)
        ec=$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null || true)
        if [ -n "$pw" ] && [ -n "$ec" ]; then
          break
        fi
      fi
      # Surface ExternalSecret condition for faster troubleshooting
      cond=$(kubectl -n "$NAMESPACE_CORE" get externalsecret rabbitmq-auth -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
      [ -n "$cond" ] && say "[rabbitmq] ESO status: $cond"
      now=$(date +%s); elapsed=$(( now - start_ts ))
      [ $elapsed -ge 90 ] && break || true
      sleep 3
    done
    if ! kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth >/dev/null 2>&1; then
      say "[error] Secret core/rabbitmq-auth not found after waiting. Ensure ESO is installed and Vault is seeded."
      say "        Try: 'just vault-seed-kv --only rabbitmq --random' (requires VAULT_TOKEN), then re-run 'just deploy-core'."
      kubectl -n "$NAMESPACE_CORE" describe externalsecret rabbitmq-auth || true
      exit 1
    fi
    # Final key presence check
    if [ -z "$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null || true)" ] || \
       [ -z "$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null || true)" ]; then
      say "[error] Secret core/rabbitmq-auth exists but missing required keys. Expected keys: rabbitmq-password, rabbitmq-erlang-cookie."
      say "        Seed values in Vault and let ESO sync, then re-run 'just deploy-core'."
      exit 1
    fi
  fi
fi

# RabbitMQ via direct HTTPS chart (no OCI)
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] curl -fsSL https://charts.bitnami.com/bitnami/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz -o .cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz && helm upgrade --install rabbitmq .cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz -n \"$NAMESPACE_CORE\" -f deploy/rabbitmq/values.yaml [with ESO creds]"
else
  mkdir -p .cache/charts
  CHART_URL="https://charts.bitnami.com/bitnami/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz"
  if ! [ -f ".cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz" ]; then
    curl -fsSL "$CHART_URL" -o ".cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz"
  fi
  # Pass ESO-provisioned credentials if present to satisfy Bitnami guard (install and upgrade)
  rb_set_flags=""
  cur_pw=$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true)
  cur_ec=$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d || true)
  if [ -n "$cur_pw" ]; then rb_set_flags="$rb_set_flags --set auth.password=\"$cur_pw\""; fi
  if [ -n "$cur_ec" ]; then rb_set_flags="$rb_set_flags --set auth.erlangCookie=\"$cur_ec\""; fi
  HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install rabbitmq \
    ".cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz" \
    -n "$NAMESPACE_CORE" -f deploy/rabbitmq/values.yaml $rb_set_flags
fi

## n8n: Community chart from community-charts repo (no OCI). Values kept minimal and schema-safe.
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] helm upgrade --install n8n community-charts/n8n -n \"$NAMESPACE_CORE\" -f deploy/n8n/community-values.yaml${N8N_CHART_VERSION:+ --version ${N8N_CHART_VERSION}}"
else
  if helm search repo community-charts/n8n 2>/dev/null | grep -q community-charts/n8n; then
    verflag=""; [ -n "${N8N_CHART_VERSION:-}" ] && verflag="--version ${N8N_CHART_VERSION}"
    HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install n8n community-charts/n8n -n "$NAMESPACE_CORE" -f deploy/n8n/community-values.yaml $verflag || true
  else
    say "[error] community-charts repo missing or out of date. Run: just helm-repos"; exit 1
  fi
fi

# (Legacy community/OCI routes removed to avoid OCI helper noise)

# Flagsmith: apply Deployment/Service/Ingress always; ExternalSecrets only if CRD serves v1beta1
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] Apply flagsmith core resources"
else
  # Always apply non-ExternalSecret docs first
  awk 'BEGIN{RS="---"} /kind:[ ]*ExternalSecret/ {next} {print $0 "\n---"}' deploy/flagsmith/deploy.yaml | kubectl apply -n "$NAMESPACE_CORE" -f -

  # If CRD exists, apply ExternalSecret docs (apiVersion should match manifests)
  if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    say "[info] Applying ExternalSecret docs for Flagsmith"
    awk 'BEGIN{RS="---"} /kind:[ ]*ExternalSecret/ {print $0 "\n---"}' deploy/flagsmith/deploy.yaml | kubectl apply -n "$NAMESPACE_CORE" -f - || {
      say "[warn] Applying ExternalSecret docs failed; continuing"; }
  else
    say "[info] ExternalSecrets CRD not found; skipped ExternalSecret docs"
  fi
fi

apply_traefik_middleware_guarded() {
  local f="deploy/traefik/n8n-auth-middleware.yaml"
  [ -f "$f" ] || return 0
  # Detect available Middleware group
  if kubectl api-resources 2>/dev/null | grep -Eiq 'traefik.*Middleware'; then
    if kubectl api-resources --api-group=traefik.io 2>/dev/null | grep -qi Middleware; then
      say "[info] Applying Traefik Middleware (traefik.io/v1alpha1)"
      sed 's#^apiVersion: .*#apiVersion: traefik.io/v1alpha1#' "$f" | kubectl apply -f -
    elif kubectl api-resources --api-group=traefik.containo.us 2>/dev/null | grep -qi Middleware; then
      say "[info] Applying Traefik Middleware (traefik.containo.us/v1alpha1)"
      sed 's#^apiVersion: .*#apiVersion: traefik.containo.us/v1alpha1#' "$f" | kubectl apply -f -
    else
      say "[info] Traefik Middleware CRD detected but group unknown; skipping apply"
    fi
  else
    say "[info] Traefik Middleware CRD not found; skipping apply"
  fi
}

# Ingress for RabbitMQ Management and n8n UI via Traefik (chart-agnostic)
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] kubectl apply -n $NAMESPACE_CORE -f deploy/rabbitmq/ingress.yaml (if present)"
  say "[dry-run] kubectl apply -n $NAMESPACE_CORE -f deploy/n8n/ingress.yaml (if present)"
else
  apply_traefik_middleware_guarded || true
  [ -f deploy/rabbitmq/ingress.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/rabbitmq/ingress.yaml || true
  [ -f deploy/rabbitmq/ingress-public.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/rabbitmq/ingress-public.yaml || true
  [ -f deploy/n8n/ingress.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/n8n/ingress.yaml || true
  [ -f deploy/n8n/ingress-public.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/n8n/ingress-public.yaml || true
fi

# n8n ExternalSecret (password env) if ESO CRD exists
if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  [ -f deploy/n8n/externalsecret.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/n8n/externalsecret.yaml || true
else
  say "[info] ExternalSecrets CRD not found; skipped n8n ExternalSecret"
fi
