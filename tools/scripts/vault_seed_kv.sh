#!/usr/bin/env bash
set -euo pipefail

DRY=0
NONINTERACTIVE=0
RANDOMIZE=0
ONLY=""
SEED_APP_SECRETS=()
NS="${NAMESPACE_INFRA:-infra}"
SVC="${VAULT_SERVICE_NAME:-vault}"
KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
PF_VAULT=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run|-n] [--non-interactive] [--random] [--only svc1,svc2] [--seed-app-secret name ...]

Seeds essential Vault KV v2 entries for this repo:
  - kv/apps/n8n/app: N8N_BASIC_AUTH_PASSWORD
  - kv/apps/rabbitmq/app: password, erlangCookie
  - kv/apps/flagsmith/app: secret-key
  - kv/apps/flagsmith/database: url (prompted; skipped if empty)

Requires: vault CLI, VAULT_ADDR and VAULT_TOKEN set (run 'just vault-init' first).
--dry-run, -n        Print what would be written
--non-interactive    Never prompt; skip values requiring input
--random             Autogenerate strong random values for applicable fields
--only               Comma-separated list of services to seed (n8n,rabbitmq,flagsmith)
--seed-app-secret    Seed kv/apps/<name>/APP_SECRET (repeatable; for Nx-generated services)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    --random) RANDOMIZE=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --seed-app-secret) SEED_APP_SECRETS+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
need_env() { [ -n "${!1:-}" ] || { echo "ERROR: env var $1 not set"; exit 1; }; }

need_cmd vault
need_cmd curl
# Default VAULT_ADDR to local port-forward if not provided
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
# Short client timeout for reachability checks
export VAULT_CLIENT_TIMEOUT="${VAULT_CLIENT_TIMEOUT:-2s}"

# Start short-lived port-forward to Vault if using localhost and not reachable
maybe_start_pf() {
  # Only attempt if VAULT_ADDR targets localhost:8200
  case "$VAULT_ADDR" in
    http://127.0.0.1:8200|http://localhost:8200|https://127.0.0.1:8200|https://localhost:8200) : ;;
    *) return 0;;
  esac

  # If Vault already responds, skip
  if vault status >/dev/null 2>&1; then return 0; fi

  if [ "$DRY" = 1 ]; then
    echo "[dry-run] (pf) kubectl -n \"$NS\" port-forward svc/$SVC 8200:8200"
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[warn] kubectl not found; cannot auto port-forward Vault. Ensure $VAULT_ADDR is reachable."
    return 0
  fi
  trap '[[ -n "$PF_VAULT" ]] && kill $PF_VAULT 2>/dev/null || true' EXIT
  (kubectl -n "$NS" port-forward "svc/$SVC" 8200:8200 >/tmp/pf_vault_seed_kv.log 2>&1 & echo $! > /tmp/pf_vault_seed_kv.pid) || true
  sleep 2
  PF_VAULT=$(cat /tmp/pf_vault_seed_kv.pid 2>/dev/null || true)

  # Wait briefly for Vault readiness
  for i in $(seq 1 10); do
    vault status >/dev/null 2>&1 && break
    sleep 1
    [ "$i" = 10 ] && echo "[warn] Vault at $VAULT_ADDR not responding yet; continuing"
  done
}

maybe_start_pf

if ! vault token lookup >/dev/null 2>&1; then
  echo "ERROR: VAULT_TOKEN invalid or not set. Run 'just vault-init' or 'source tools/secrets/.envrc.vault'."
  exit 1
fi

# Ensure KV v2 mount exists at "$KV_MOUNT"; attempt to create/upgrade if permitted
ensure_kv_mount() {
  # Fast path: if mount present, optionally upgrade to v2
  if vault secrets list 2>/dev/null | awk '{print $1}' | grep -q "^${KV_MOUNT}/$"; then
    if ! vault read "${KV_MOUNT}/config" >/dev/null 2>&1; then
      # Not v2; try to enable versioning
      vault kv enable-versioning -mount="$KV_MOUNT" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  # Try to enable kv-v2 at the expected mount path
  if vault secrets enable -path="$KV_MOUNT" kv-v2 >/dev/null 2>&1; then
    echo "[vault] Enabled KV v2 at path '$KV_MOUNT'"
    return 0
  fi
  # If we cannot enable (policy), print actionable guidance
  echo "[warn] KV mount '$KV_MOUNT/' not found and could not be enabled with current token."
  echo "       Run: just sso-bootstrap (or manually: vault secrets enable -path=$KV_MOUNT kv-v2)"
  return 1
}

ensure_kv_mount || true

in_only() {
  local name="$1"
  [ -z "$ONLY" ] && return 0
  IFS=',' read -r -a arr <<< "$ONLY"
  for x in "${arr[@]}"; do [ "$x" = "$name" ] && return 0; done
  return 1
}

rand_b64() { openssl rand -base64 "${1:-32}" | tr -d '\n' ; }
# Avoid SIGPIPE under set -o pipefail by using process substitution
rand_cookie() { LC_ALL=C head -c 32 < <(tr -dc 'A-Z0-9' </dev/urandom) ; }

say_do() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else eval "$*"; fi }

# Write to KV v2 using kv subcommand and explicit mount (bypasses UI mounts preflight)
# Usage: kv_v2_put_pairs "apps/foo/bar" "k1=v1" "k2=v2" ...
json_escape() {
  # Escapes for JSON string values
  sed -e 's/\\/\\\\/g' \
      -e 's/"/\\"/g' \
      -e 's/\t/\\t/g' \
      -e 's/\r/\\r/g' \
      -e 's/\n/\\n/g'
}

json_from_pairs() {
  # Input: k=v pairs as args; Output: {"data":{"k":"v",...}}
  local first=1 k v json='{"data":{'
  while [ "$#" -gt 0 ]; do
    k=${1%%=*}; v=${1#*=}
    # ensure both key and value are present
    if [ -z "$k" ]; then shift; continue; fi
    esc_v=$(printf '%s' "$v" | json_escape)
    if [ $first -eq 1 ]; then
      json="$json\"$k\":\"$esc_v\""
      first=0
    else
      json="$json,\"$k\":\"$esc_v\""
    fi
    shift
  done
  json="$json}"}
  printf '%s' "$json"
}

kv_v2_put_pairs() {
  local rel="$1"; shift
  if [ "$DRY" = 1 ]; then
    # Print a readable command preview
    printf "[dry-run] vault kv put -mount=\"%s\" %s" "$KV_MOUNT" "$rel"
    for arg in "$@"; do printf " %q" "$arg"; done
    printf "\n"
    return 0
  fi

  # First try: vault kv put (may preflight sys/internal/ui/mounts and 403 with limited tokens)
  local err
  err=$(mktemp)
  if vault kv put -mount="$KV_MOUNT" "$rel" "$@" >/dev/null 2>"$err"; then
    rm -f "$err"; return 0
  fi
  if grep -qi 'sys/internal/ui/mounts' "$err" || grep -qi 'preflight capability check returned 403' "$err"; then
    # Fallback: direct HTTP API to avoid UI preflight. Requires create/update on $KV_MOUNT/data/<rel>.
    local json
    json=$(json_from_pairs "$@")
    if curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN:-}" -H 'Content-Type: application/json' \
         -X POST --data "$json" "$VAULT_ADDR/v1/${KV_MOUNT}/data/${rel}" >/dev/null; then
      rm -f "$err"; return 0
    else
      echo "ERROR: HTTP API write to ${KV_MOUNT}/data/${rel} failed." >&2
      echo "Hint: Ensure VAULT_TOKEN has create/update on path \"${KV_MOUNT}/data/apps/*\"." >&2
      rm -f "$err"; return 1
    fi
  fi
  echo "ERROR: vault kv put failed:" >&2
  cat "$err" >&2
  rm -f "$err"
  return 1
}

# n8n
if in_only n8n; then
  N8N_PWD=""
  if [ "$RANDOMIZE" = 1 ]; then N8N_PWD=$(rand_b64 24); fi
  if [ -z "$N8N_PWD" ] && [ "$NONINTERACTIVE" = 0 ]; then
    read -r -s -p "n8n basic auth password (leave blank to autogenerate): " N8N_PWD_INP || true; echo
    if [ -z "$N8N_PWD_INP" ]; then N8N_PWD=$(rand_b64 24); else N8N_PWD="$N8N_PWD_INP"; fi
  fi
  if [ -n "$N8N_PWD" ]; then
    kv_v2_put_pairs "apps/n8n/app" "N8N_BASIC_AUTH_PASSWORD=$N8N_PWD"
    echo "[ok] Wrote kv/apps/n8n/app:N8N_BASIC_AUTH_PASSWORD"
  fi
fi

# rabbitmq
if in_only rabbitmq; then
  RMQ_PWD=""; RMQ_COOKIE=""
  if [ "$RANDOMIZE" = 1 ] || [ "$NONINTERACTIVE" = 1 ]; then
    RMQ_PWD=$(rand_b64 24); RMQ_COOKIE=$(rand_cookie)
  else
    read -r -s -p "RabbitMQ password (leave blank to autogenerate): " RMQ_PWD_INP || true; echo
    read -r -p "RabbitMQ erlangCookie (uppercase A-Z0-9, blank to autogenerate): " RMQ_COOKIE_INP || true
    [ -z "$RMQ_PWD_INP" ] && RMQ_PWD=$(rand_b64 24) || RMQ_PWD="$RMQ_PWD_INP"
    [ -z "$RMQ_COOKIE_INP" ] && RMQ_COOKIE=$(rand_cookie) || RMQ_COOKIE="$RMQ_COOKIE_INP"
  fi
  kv_v2_put_pairs "apps/rabbitmq/app" "password=$RMQ_PWD" "erlangCookie=$RMQ_COOKIE"
  echo "[ok] Wrote kv/apps/rabbitmq/app:{password,erlangCookie}"
fi

# flagsmith
if in_only flagsmith; then
  FMSK=""; DBURL=""
  if [ "$RANDOMIZE" = 1 ]; then FMSK=$(rand_b64 32); fi
  if [ -z "$FMSK" ] && [ "$NONINTERACTIVE" = 0 ]; then
    read -r -s -p "Flagsmith SECRET_KEY (blank to autogenerate): " FMSK_INP || true; echo
    if [ -z "$FMSK_INP" ]; then FMSK=$(rand_b64 32); else FMSK="$FMSK_INP"; fi
  fi
  kv_v2_put_pairs "apps/flagsmith/app" "secret-key=$FMSK"
  echo "[ok] Wrote kv/apps/flagsmith/app:secret-key"

  if [ "$NONINTERACTIVE" = 0 ]; then
    read -r -p "Flagsmith DATABASE_URL (postgres://... ; blank to skip): " DBURL || true
  fi
  if [ -n "${DBURL:-}" ]; then
    kv_v2_put_pairs "apps/flagsmith/database" "url=$DBURL"
    echo "[ok] Wrote kv/apps/flagsmith/database:url"
  else
    echo "[note] Skipped kv/apps/flagsmith/database:url (set later if needed)"
  fi
fi

echo "Done. ESO will sync these to Kubernetes if configured."

# Generic APP_SECRET seeding for Nx-generated services
for svc in "${SEED_APP_SECRETS[@]:-}"; do
  [ -z "$svc" ] && continue
  APPSEC=""
  if [ "$RANDOMIZE" = 1 ] || [ "$NONINTERACTIVE" = 1 ]; then
    APPSEC=$(rand_b64 32)
  else
    read -r -s -p "APP_SECRET for ${svc} (blank to autogenerate): " INP || true; echo
    [ -z "$INP" ] && APPSEC=$(rand_b64 32) || APPSEC="$INP"
  fi
  kv_v2_put_pairs "apps/${svc}/APP_SECRET" "APP_SECRET=$APPSEC"
  echo "[ok] Wrote kv/apps/${svc}/APP_SECRET:APP_SECRET"
done
