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
export HELM_NO_CREDS := env_var_or_default("HELM_NO_CREDS", "0") # If 1, use minimal DOCKER_CONFIG to avoid secretservice helper
export HELM_REGISTRY_CONFIG := env_var_or_default("HELM_REGISTRY_CONFIG", ".helm-registry/config.json") # Override to custom registry config
export RABBITMQ_CHART_VERSION := env_var_or_default("RABBITMQ_CHART_VERSION", "16.0.14")
export N8N_CHART_VERSION := env_var_or_default("N8N_CHART_VERSION", "")

# Safety switch: require explicit opt-in to WRITE MetalLB pool file.
# Detection will still display proposed range. Set WRITE_METALLB=1 to apply.
export WRITE_METALLB := env_var_or_default("WRITE_METALLB", "0")
export INSTALL_DRY_RUN := env_var_or_default("INSTALL_DRY_RUN", "0")
export ADOPT_EXISTING := env_var_or_default("ADOPT_EXISTING", "0")

helm-repos:
	# Ensure minimal custom Helm registry config (avoids using user keyring when empty/anon pulls)
	@if [ ! -f "${HELM_REGISTRY_CONFIG}" ]; then \
		mkdir -p "$(dirname ${HELM_REGISTRY_CONFIG})"; echo '{}' > "${HELM_REGISTRY_CONFIG}"; \
		printf '[helm] Created minimal registry config at %s\n' "${HELM_REGISTRY_CONFIG}"; \
	fi
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
	# Wrapper to install namespaces, ESO, Cilium (unless SKIP_CILIUM=true), MetalLB, Vault, ArgoCD
	bash tools/scripts/install_foundation.sh

configure-network:
	# Detect default IPv4 and write deploy/metallb/ipaddresspool.yaml
	python3 tools/scripts/configure_network.py

vault-init:
	# One-click Vault init/unseal and VAULT_TOKEN helper
	bash tools/scripts/vault_init.sh

sso-bootstrap: helm-repos
	# Install Ory stack, oauth2-proxy(+Redis), onboard Vault K8s auth, and register Hydra clients
	bash tools/scripts/vault_k8s_onboard.sh || true
	python3 tools/scripts/hydra_clients.py || true


deploy-obs: helm-repos
	# Support INSTALL_DRY_RUN=1 to print actions instead of performing changes.
	if [ "${INSTALL_DRY_RUN}" = "1" ]; then \
		echo "[dry-run] helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n \"$NAMESPACE_OBS\" -f deploy/observability/otel-values.yaml"; \
		echo "[dry-run] helm upgrade --install loki grafana/loki -n \"$NAMESPACE_OBS\" -f deploy/observability/loki-values.yaml"; \
		echo "[dry-run] helm upgrade --install tempo grafana/tempo -n \"$NAMESPACE_OBS\" -f deploy/observability/tempo-values.yaml"; \
		echo "[dry-run] helm upgrade --install mimir grafana/mimir-distributed -n \"$NAMESPACE_OBS\" -f deploy/observability/mimir-values.yaml"; \
		echo "[dry-run] helm upgrade --install grafana grafana/grafana -n \"$NAMESPACE_OBS\" -f deploy/observability/grafana-values.yaml"; \
	else \
		helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n "$NAMESPACE_OBS" -f deploy/observability/otel-values.yaml; \
		helm upgrade --install loki grafana/loki -n "$NAMESPACE_OBS" -f deploy/observability/loki-values.yaml; \
		helm upgrade --install tempo grafana/tempo -n "$NAMESPACE_OBS" -f deploy/observability/tempo-values.yaml; \
		helm upgrade --install mimir grafana/mimir-distributed -n "$NAMESPACE_OBS" -f deploy/observability/mimir-values.yaml || true; \
		helm upgrade --install grafana grafana/grafana -n "$NAMESPACE_OBS" -f deploy/observability/grafana-values.yaml; \
	fi

deploy-ux:
	# Support INSTALL_DRY_RUN=1 to print actions instead of performing changes.
	if [ "${INSTALL_DRY_RUN}" = "1" ]; then \
		echo "[dry-run] helm upgrade --install homepage --namespace \"$NAMESPACE_CORE\" --create-namespace oci://ghcr.io/gethomepage/homepage --version 0.9.11"; \
		echo "[dry-run] kubectl apply -n \"$NAMESPACE_CORE\" -f deploy/guacamole/guacd.yaml --dry-run=client"; \
		echo "[dry-run] kubectl apply -n \"$NAMESPACE_CORE\" -f deploy/guacamole/guacamole.yaml --dry-run=client"; \
		echo "[dry-run] kubectl apply -n \"$NAMESPACE_CORE\" -f deploy/vaultwarden/deploy.yaml --dry-run=client"; \
		echo "[dry-run] kubectl apply -n \"$NAMESPACE_CORE\" -f deploy/mcp/contextforge.yaml --dry-run=client"; \
	else \
		helm upgrade --install homepage --namespace "$NAMESPACE_CORE" --create-namespace oci://ghcr.io/gethomepage/homepage --version 0.9.11 || true; \
		kubectl apply -n "$NAMESPACE_CORE" -f deploy/guacamole/guacd.yaml; \
		kubectl apply -n "$NAMESPACE_CORE" -f deploy/guacamole/guacamole.yaml; \
		kubectl apply -n "$NAMESPACE_CORE" -f deploy/vaultwarden/deploy.yaml; \
		kubectl apply -n "$NAMESPACE_CORE" -f deploy/mcp/contextforge.yaml; \
	fi

gitops:
	kubectl apply -n argocd -f deploy/argocd/app-of-apps.yaml || true

deploy-core: helm-repos
	# Delegated deploy logic moved to wrapper script to avoid Justfile multiline fragility
	bash tools/scripts/deploy_core.sh
audit:
	# Environment and cluster readiness checks; writes tools/audit/reports/
	python3 tools/audit/audit_readiness.py

doctor: audit
