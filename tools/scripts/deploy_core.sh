#!/usr/bin/env bash
set -euo pipefail

NAMESPACE_CORE=${NAMESPACE_CORE:-core}
INSTALL_DRY_RUN=${INSTALL_DRY_RUN:-0}
HELM_REGISTRY_CONFIG=${HELM_REGISTRY_CONFIG:-.helm-registry/config.json}
HELM_NO_CREDS=${HELM_NO_CREDS:-0}
RABBITMQ_CHART_VERSION=${RABBITMQ_CHART_VERSION:-16.0.14}
N8N_CHART_VERSION=${N8N_CHART_VERSION:-}

say(){ printf '%s\n' "$*"; }
run(){ if [ "$INSTALL_DRY_RUN" = "1" ]; then echo "(dry-run) $*"; else eval "$*"; fi }

# Optional creds bypass
if [ "$HELM_NO_CREDS" = "1" ]; then
  mkdir -p .docker-nocreds
  [ -f .docker-nocreds/config.json ] || echo '{}' > .docker-nocreds/config.json
  export DOCKER_CONFIG="$PWD/.docker-nocreds"
  say "[info] HELM_NO_CREDS=1 using DOCKER_CONFIG=$DOCKER_CONFIG"
fi

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

# RabbitMQ with fallback to HTTPS chart
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] helm upgrade --install rabbitmq bitnami/rabbitmq -n \"$NAMESPACE_CORE\" -f deploy/rabbitmq/values.yaml"
else
  # Pass ESO-provisioned credentials if present to satisfy Bitnami guard (install and upgrade)
  rb_set_flags=""
  cur_pw=$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' 2>/dev/null | base64 -d || true)
  cur_ec=$(kubectl -n "$NAMESPACE_CORE" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d || true)
  if [ -n "$cur_pw" ]; then rb_set_flags="$rb_set_flags --set auth.password=\"$cur_pw\""; fi
  if [ -n "$cur_ec" ]; then rb_set_flags="$rb_set_flags --set auth.erlangCookie=\"$cur_ec\""; fi
  if ! eval HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install rabbitmq bitnami/rabbitmq -n "$NAMESPACE_CORE" -f deploy/rabbitmq/values.yaml --version "$RABBITMQ_CHART_VERSION" $rb_set_flags 2> >(tee /tmp/helm_rabbitmq.err >&2); then
    if grep -Eqi 'org\.freedesktop\.secrets|secretservice|docker-credential|FetchReference|registry-1\.docker\.io|bitnamicharts' /tmp/helm_rabbitmq.err; then
      say "[warn] Helm encountered a credential helper/OCI fetch issue. Falling back to direct HTTPS chart download."
      mkdir -p .cache/charts
      CHART_URL="https://charts.bitnami.com/bitnami/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz"
      if curl -fsSL "$CHART_URL" -o .cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz; then
        eval HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install rabbitmq .cache/charts/rabbitmq-${RABBITMQ_CHART_VERSION}.tgz -n "$NAMESPACE_CORE" -f deploy/rabbitmq/values.yaml $rb_set_flags
      else
        say "[error] Fallback download failed: $CHART_URL"; exit 1
      fi
    else
      say "[error] RabbitMQ helm upgrade failed (see details)"; cat /tmp/helm_rabbitmq.err; exit 1
    fi
  fi
fi

# n8n: prefer community-charts index; otherwise fall back to Bitnami (index/OCI/HTTPS)
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] n8n helm action (prefer community-charts, else bitnami or OCI)"
else
  # 1) Community Helm Charts repo (HTTPS index, no secretservice)
  if helm search repo community-charts/n8n 2>/dev/null | grep -q community-charts/n8n; then
    verflag=""; [ -n "$N8N_CHART_VERSION" ] && verflag="--version $N8N_CHART_VERSION"
    valuesflag=""; if [ "${N8N_USE_COMMUNITY_VALUES:-0}" = "1" ] && [ -f deploy/n8n/community-values.yaml ]; then valuesflag="-f deploy/n8n/community-values.yaml"; fi
    # Community chart; optionally use our values if explicitly enabled
    helm upgrade --install n8n community-charts/n8n -n "$NAMESPACE_CORE" $verflag $valuesflag || true
  else
    # 2) Bitnami repo if present
    if helm search repo bitnami/n8n 2>/dev/null | grep -q bitnami/n8n; then
      verflag=""; [ -n "$N8N_CHART_VERSION" ] && verflag="--version $N8N_CHART_VERSION"
      HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install n8n bitnami/n8n -n "$NAMESPACE_CORE" -f deploy/n8n/values.yaml $verflag || true
    else
      # 3) OCI artifact from Docker Hub (may hit secretservice); on secretservice error, fallback to HTTPS if version provided
      say "[info] n8n not found in index; using OCI artifact"
      if ! HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install n8n oci://registry-1.docker.io/bitnamicharts/n8n -n "$NAMESPACE_CORE" -f deploy/n8n/values.yaml 2> >(tee /tmp/helm_n8n.err >&2); then
        if grep -Eqi 'org\.freedesktop\.secrets|secretservice|docker-credential|FetchReference|registry-1\.docker\.io|bitnamicharts' /tmp/helm_n8n.err; then
          if [ -n "$N8N_CHART_VERSION" ]; then
            say "[warn] OCI fetch hit secretservice for n8n. Falling back to direct HTTPS chart download (Bitnami) version $N8N_CHART_VERSION."
            mkdir -p .cache/charts
            CHART_URL="https://charts.bitnami.com/bitnami/n8n-${N8N_CHART_VERSION}.tgz"
            if curl -fsSL "$CHART_URL" -o .cache/charts/n8n-${N8N_CHART_VERSION}.tgz; then
              HELM_REGISTRY_CONFIG="$HELM_REGISTRY_CONFIG" helm upgrade --install n8n .cache/charts/n8n-${N8N_CHART_VERSION}.tgz -n "$NAMESPACE_CORE" -f deploy/n8n/values.yaml || true
            else
              say "[warn] n8n HTTPS fallback download failed: $CHART_URL"
            fi
          else
            say "[warn] n8n OCI failed due to credential helper and N8N_CHART_VERSION is not set; set N8N_CHART_VERSION (Bitnami chart version) to enable HTTPS fallback, or add 'community-charts' repo."
          fi
        else
          say "[warn] n8n helm upgrade failed (non secretservice error); see /tmp/helm_n8n.err"
          cat /tmp/helm_n8n.err || true
        fi
      fi
    fi
  fi
fi

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
    say "[warn] ExternalSecrets CRD missing; skipped ExternalSecret docs"
  fi
fi

# Ingress for RabbitMQ Management and n8n UI via Traefik (chart-agnostic)
if [ "$INSTALL_DRY_RUN" = "1" ]; then
  say "[dry-run] kubectl apply -n $NAMESPACE_CORE -f deploy/rabbitmq/ingress.yaml (if present)"
  say "[dry-run] kubectl apply -n $NAMESPACE_CORE -f deploy/n8n/ingress.yaml (if present)"
else
  [ -f deploy/traefik/n8n-auth-middleware.yaml ] && kubectl apply -f deploy/traefik/n8n-auth-middleware.yaml || true
  [ -f deploy/rabbitmq/ingress.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/rabbitmq/ingress.yaml || true
  [ -f deploy/rabbitmq/ingress-public.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/rabbitmq/ingress-public.yaml || true
  [ -f deploy/n8n/ingress.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/n8n/ingress.yaml || true
  [ -f deploy/n8n/ingress-public.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/n8n/ingress-public.yaml || true
fi

# n8n ExternalSecret (password env) if ESO CRD exists
if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  [ -f deploy/n8n/externalsecret.yaml ] && kubectl apply -n "$NAMESPACE_CORE" -f deploy/n8n/externalsecret.yaml || true
else
  say "[warn] ExternalSecrets CRD missing; skipped n8n ExternalSecret"
fi
