#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE_INFRA:-infra}"
SVC="${VAULT_SERVICE_NAME:-vault}"
ENV_FILE="tools/secrets/.envrc.vault"
DRY_RUN=0

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=1; shift;;
    *) shift;;
  esac
done

# also respect env var for CI or Just usage
if [ "${VAULT_INIT_DRY_RUN:-}" = "1" ] || [ "${INSTALL_DRY_RUN:-0}" = "1" ]; then
  DRY_RUN=1
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: vault CLI not found. Install HashiCorp Vault CLI and try again."
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found."
  exit 1
fi

mkdir -p tools/secrets

echo "== Vault init helper =="
echo "Namespace: $NS  Service: $SVC"
echo "Starting short-lived port-forward to $NS/$SVC on 127.0.0.1:8200..."

PF_VAULT=""
trap '[[ -n "$PF_VAULT" ]] && kill $PF_VAULT 2>/dev/null || true' EXIT
(kubectl -n "$NS" port-forward "svc/$SVC" 8200:8200 >/tmp/pf_vault_init.log 2>&1 & echo $! > /tmp/pf_vault_init.pid) || true
sleep 2
PF_VAULT=$(cat /tmp/pf_vault_init.pid || true)

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

echo "Checking Vault status at $VAULT_ADDR ..."
STATUS_JSON=""
if vault status -format=json >/tmp/vault_status.json 2>/dev/null; then
  STATUS_JSON=$(cat /tmp/vault_status.json)
fi

initialized="unknown"
sealed="unknown"

if [[ -n "$STATUS_JSON" ]]; then
  initialized=$(grep -o '"initialized":[^,]*' /tmp/vault_status.json | awk -F: '{print $2}' | tr -d ' ')
  sealed=$(grep -o '"sealed":[^,]*' /tmp/vault_status.json | awk -F: '{print $2}' | tr -d ' ')
else
  OUT=$(vault status || true)
  if echo "$OUT" | grep -qi "Initialized.*true"; then initialized="true"; else initialized="false"; fi
  if echo "$OUT" | grep -qi "Sealed.*true"; then sealed="true"; else sealed="false"; fi
fi

echo "initialized=$initialized  sealed=$sealed"

write_env_file() {
  local token="$1"
  read -r -p "Write VAULT_TOKEN to $ENV_FILE (chmod 600)? [y/N] " ans || true
  if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
    umask 177
    mkdir -p "$(dirname "$ENV_FILE")"
    printf 'export VAULT_ADDR=%q\nexport VAULT_TOKEN=%q\n' "$VAULT_ADDR" "$token" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Wrote $ENV_FILE (permissions 600)."
    echo "Tip: Ensure your project .envrc contains:"
    echo "  source_env_if_exists tools/secrets/.envrc.vault"
  else
    echo "Not writing env file. Remember to: export VAULT_TOKEN=<token>"
  fi
}

if [[ "$initialized" == "false" ]]; then
  echo "Vault is not initialized."
  read -r -p "Initialize Vault now with 1 unseal key and 1 threshold? [y/N] " ans || true
  if [[ ! "${ans:-}" =~ ^[Yy]$ ]]; then
    echo "Aborting init per user choice."
    exit 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "(dry-run) Would run: vault operator init -key-shares=1 -key-threshold=1"
    echo "(dry-run) Skipping actual init."
    echo "(dry-run) Example output: Unseal Key 1: <redacted>\nInitial Root Token: <redacted>"
    exit 0
  fi

  echo "Initializing..."
  INIT_OUT=$(vault operator init -key-shares=1 -key-threshold=1)
  echo "===== IMPORTANT SECRETS (DISPLAY ONLY) ====="
  echo "$INIT_OUT"
  echo "===== END SECRETS ====="
  UNSEAL=$(echo "$INIT_OUT" | grep 'Unseal Key 1:' | awk '{print $4}')
  ROOT=$(echo "$INIT_OUT" | grep 'Initial Root Token:' | awk '{print $4}')
  if [[ -z "$UNSEAL" || -z "$ROOT" ]]; then
    echo "Failed to parse unseal or root token. Please re-run and/or copy manually."
    exit 1
  fi
  echo "Unsealing once..."
  vault operator unseal "$UNSEAL" >/dev/null
  export VAULT_TOKEN="$ROOT"
  echo "Exported VAULT_TOKEN for this process only."
  write_env_file "$ROOT"
  echo "Initialization complete."
  echo "TIP: Store the Unseal Key and Root Token safely in your password manager (Vaultwarden) and delete any copies."
  exit 0
fi

if [[ "$sealed" == "true" ]]; then
  echo "Vault is initialized but sealed."
  read -r -s -p "Enter Unseal Key: " UNSEAL_KEY
  echo
  if [[ -z "$UNSEAL_KEY" ]]; then
    echo "No unseal key provided; aborting."
    exit 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "(dry-run) Would run: vault operator unseal <provided-key>"
  else
    vault operator unseal "$UNSEAL_KEY" >/dev/null
  fi
  echo "Unsealed."
fi

HAS_TOKEN=0
if vault token lookup >/dev/null 2>&1; then
  HAS_TOKEN=1
fi

if [[ "$HAS_TOKEN" -ne 1 ]]; then
  echo "No valid VAULT_TOKEN in environment."
  read -r -s -p "Enter an admin/root token to export for this shell: " TOK
  echo
  if [[ -z "$TOK" ]]; then
    echo "No token provided; continuing without exporting."
  else
    if [ "$DRY_RUN" = "1" ]; then
      echo "(dry-run) Would export VAULT_TOKEN and offer to write $ENV_FILE"
    else
      export VAULT_TOKEN="$TOK"
      echo "Exported VAULT_TOKEN for this process."
      write_env_file "$TOK"
    fi
  fi
fi

echo "Vault is ready. You can now run: 'just sso-bootstrap'."
