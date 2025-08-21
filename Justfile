set shell := ["bash", "-cu"]

# ---------------------------------------------------------------------------
# Global configuration (override by: just VAR=value <recipe> OR exporting env)
# Using env_var_or_default so users can safely override without editing file.
# ---------------------------------------------------------------------------
export DOMAIN := env_var_or_default("DOMAIN", "homelab.lan")
export METALLB_POOL_CIDR := env_var_or_default("METALLB_POOL_CIDR", "192.168.1.240-192.168.1.250")
export NAMESPACE_SSO := env_var_or_default("NAMESPACE_SSO", "sso")
export NAMESPACE_OBS := env_var_or_default("NAMESPACE_OBS", "observability")
export NAMESPACE_CORE := env_var_or_default("NAMESPACE_CORE", "core")
export NAMESPACE_INFRA := env_var_or_default("NAMESPACE_INFRA", "infra")
export HYDRA_ADMIN_URL := "http://hydra-admin." + NAMESPACE_SSO + ".svc.cluster.local:4445"
export KRATOS_PUBLIC_URL := "http://kratos-public." + NAMESPACE_SSO + ".svc.cluster.local:4433"
export OAUTH2_PROXY_REDIS_ENABLED := env_var_or_default("OAUTH2_PROXY_REDIS_ENABLED", "true")

# Safety switch: require explicit opt-in to WRITE MetalLB pool file.
# Detection will still display proposed range. Set WRITE_METALLB=1 to apply.
export WRITE_METALLB := env_var_or_default("WRITE_METALLB", "0")
export INSTALL_DRY_RUN := env_var_or_default("INSTALL_DRY_RUN", "0")
export ADOPT_EXISTING := env_var_or_default("ADOPT_EXISTING", "0")

helm-repos:
	helm repo add cilium https://helm.cilium.io || true
	helm repo add metallb https://metallb.github.io/metallb || true
	helm repo add hashicorp https://helm.releases.hashicorp.com || true
	helm repo add argo https://argoproj.github.io/argo-helm || true
	helm repo add grafana https://grafana.github.io/helm-charts || true
	helm repo add bitnami https://charts.bitnami.com/bitnami || true
	helm repo add external-secrets https://charts.external-secrets.io || true
	helm repo add ory https://k8s.ory.sh/helm/charts || true
	helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests || true
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
	helm repo update

install-foundation: helm-repos
	bash tools/scripts/install_foundation.sh

sso-bootstrap: helm-repos
	# Auto-detect LAN and (optionally) adjust MetalLB pool.
	if [ "${WRITE_METALLB}" = "1" ]; then \
	  echo "[network] Detecting + writing MetalLB pool (override with WRITE_METALLB=0)"; \
	  python3 tools/scripts/configure_network.py --write || true; \
	else \
	  echo "[network] Dry-run detection only (set WRITE_METALLB=1 to apply changes)"; \
	  python3 tools/scripts/configure_network.py || true; \
	fi

	helm upgrade --install kratos ory/kratos -n "$NAMESPACE_SSO" -f deploy/ory/kratos-values.yaml
	helm upgrade --install hydra ory/hydra -n "$NAMESPACE_SSO" -f deploy/ory/hydra-values.yaml

	if [ "${OAUTH2_PROXY_REDIS_ENABLED}" = "true" ]; then \
	  helm upgrade --install redis bitnami/redis -n "$NAMESPACE_SSO" -f deploy/redis/values.yaml; \
	fi
	helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy -n "$NAMESPACE_SSO" -f deploy/oauth2-proxy/values.yaml

	# Start short-lived port-forwards (Hydra admin 4445, Vault 8200)
	set -e
	PF_HYDRA=""; PF_VAULT="";
	trap '[[ -n "$PF_HYDRA" ]] && kill $PF_HYDRA 2>/dev/null || true; [[ -n "$PF_VAULT" ]] && kill $PF_VAULT 2>/dev/null || true' EXIT
	(kubectl -n "$NAMESPACE_SSO" port-forward svc/hydra-admin 4445:4445 >/tmp/pf_hydra.log 2>&1 & echo $! > /tmp/pf_hydra.pid)
	sleep 2
	PF_HYDRA=$(cat /tmp/pf_hydra.pid || true)
	(kubectl -n "$NAMESPACE_INFRA" port-forward svc/vault 8200:8200 >/tmp/pf_vault.log 2>&1 & echo $! > /tmp/pf_vault.pid) || true
	sleep 2
	PF_VAULT=$(cat /tmp/pf_vault.pid || true)

	# Use localhost endpoints for admin APIs
	export HYDRA_ADMIN_URL="http://127.0.0.1:4445"
	export VAULT_ADDR="http://127.0.0.1:8200"

	# Vault onboarding (requires VAULT_TOKEN). Skip if not present.
	if [ -n "${VAULT_TOKEN:-}" ]; then \
	  echo "Running Vault onboarding with VAULT_TOKEN (k8s auth + ESO role)"; \
	  bash tools/scripts/vault_k8s_onboard.sh || true; \
	else \
	  echo "VAULT_TOKEN not set; skipping Vault onboarding. Set VAULT_TOKEN and re-run sso-bootstrap to enable."; \
	fi

	# Register Hydra clients idempotently
	python3 tools/scripts/hydra_clients.py --admin "$HYDRA_ADMIN_URL" --domain "$DOMAIN" --config deploy/ory/clients.yaml

deploy-core: helm-repos
	helm upgrade --install rabbitmq bitnami/rabbitmq -n "$NAMESPACE_CORE" -f deploy/rabbitmq/values.yaml
	helm upgrade --install n8n bitnami/n8n -n "$NAMESPACE_CORE" -f deploy/n8n/values.yaml || true
	kubectl apply -n "$NAMESPACE_CORE" -f deploy/flagsmith/deploy.yaml

deploy-obs: helm-repos
	helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n "$NAMESPACE_OBS" -f deploy/observability/otel-values.yaml
	helm upgrade --install loki grafana/loki -n "$NAMESPACE_OBS" -f deploy/observability/loki-values.yaml
	helm upgrade --install tempo grafana/tempo -n "$NAMESPACE_OBS" -f deploy/observability/tempo-values.yaml
	helm upgrade --install mimir grafana/mimir-distributed -n "$NAMESPACE_OBS" -f deploy/observability/mimir-values.yaml || true
	helm upgrade --install grafana grafana/grafana -n "$NAMESPACE_OBS" -f deploy/observability/grafana-values.yaml

deploy-ux:
	helm upgrade --install homepage --namespace "$NAMESPACE_CORE" --create-namespace oci://ghcr.io/gethomepage/homepage --version 0.9.11 || true
	kubectl apply -n "$NAMESPACE_CORE" -f deploy/guacamole/guacd.yaml
	kubectl apply -n "$NAMESPACE_CORE" -f deploy/guacamole/guacamole.yaml
	kubectl apply -n "$NAMESPACE_CORE" -f deploy/vaultwarden/deploy.yaml
	kubectl apply -n "$NAMESPACE_CORE" -f deploy/mcp/contextforge.yaml

gitops:
	kubectl apply -n argocd -f deploy/argocd/app-of-apps.yaml || true

generate service:
	pnpm nx g @org/nx-homelab-plugin:service {{service}}

audit:
	@mkdir -p tools/audit/reports
	@python3 tools/audit/audit_readiness.py --format both --out tools/audit/reports

audit-quick:
	@bash tools/audit/audit_wsl.sh

audit-windows:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File tools/audit/audit_windows.ps1

doctor: audit-quick audit
	@echo "Doctor completed. See tools/audit/reports/readiness.md"

# Detect host IP/CIDR and write MetalLB pool safely
configure-network:
	@if [ "${WRITE_METALLB}" = "1" ]; then \
	  python3 tools/scripts/configure_network.py --write || true; \
	else \
	  python3 tools/scripts/configure_network.py || true; \
	  echo "(Dry run only. Set WRITE_METALLB=1 to modify MetalLB pool file.)"; \
	fi

# Initialize and/or unseal Vault with safe prompts and optional env file
vault-init:
	bash tools/scripts/vault_init.sh
