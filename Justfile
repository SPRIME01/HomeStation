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
export N8N_CHART_VERSION := env_var_or_default("N8N_CHART_VERSION", "1.15.2")
export N8N_USE_COMMUNITY_VALUES := env_var_or_default("N8N_USE_COMMUNITY_VALUES", "1")
export PROMTAIL_ENABLED := env_var_or_default("PROMTAIL_ENABLED", "0")

# Safety switch: require explicit opt-in to WRITE MetalLB pool file.
# Detection will still display proposed range. Set WRITE_METALLB=1 to apply.
export WRITE_METALLB := env_var_or_default("WRITE_METALLB", "0")
export INSTALL_DRY_RUN := env_var_or_default("INSTALL_DRY_RUN", "0")
export ADOPT_EXISTING := env_var_or_default("ADOPT_EXISTING", "0")

helm-repos +args='*':
	# Ensure minimal custom Helm registry config (avoids using user keyring when empty/anon pulls)
	# Support --dry-run/-n as a convenience flag
	DRY=${INSTALL_DRY_RUN:-0}; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ "$DRY" = "1" ]; then \
		if [ ! -f "${HELM_REGISTRY_CONFIG}" ]; then \
			echo "[dry-run] mkdir -p \"$(dirname ${HELM_REGISTRY_CONFIG})\" && echo '{}' > \"${HELM_REGISTRY_CONFIG}\""; \
		else \
			echo "[dry-run] (exists) ${HELM_REGISTRY_CONFIG}"; \
		fi; \
		echo "[dry-run] helm repo add cilium https://helm.cilium.io || true"; \
		echo "[dry-run] helm repo add metallb https://metallb.github.io/metallb || true"; \
		echo "[dry-run] helm repo add hashicorp https://helm.releases.hashicorp.com || true"; \
		echo "[dry-run] helm repo add argo https://argoproj.github.io/argo-helm || true"; \
		echo "[dry-run] helm repo add grafana https://grafana.github.io/helm-charts || true"; \
		echo "[dry-run] helm repo add bitnami https://charts.bitnami.com/bitnami || true"; \
		echo "[dry-run] helm repo add external-secrets https://charts.external-secrets.io || true"; \
		echo "[dry-run] helm repo add ory https://k8s.ory.sh/helm/charts || true"; \
		echo "[dry-run] helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests || true"; \
		echo "[dry-run] helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true"; \
			echo "[dry-run] helm repo update"; \
		else \
		if [ ! -f "${HELM_REGISTRY_CONFIG}" ]; then \
			mkdir -p "$(dirname ${HELM_REGISTRY_CONFIG})"; echo '{}' > "${HELM_REGISTRY_CONFIG}"; \
			printf '[helm] Created minimal registry config at %s\n' "${HELM_REGISTRY_CONFIG}"; \
		fi; \
		helm repo add cilium https://helm.cilium.io || true; \
		helm repo add metallb https://metallb.github.io/metallb || true; \
		helm repo add hashicorp https://helm.releases.hashicorp.com || true; \
		helm repo add argo https://argoproj.github.io/argo-helm || true; \
		helm repo add grafana https://grafana.github.io/helm-charts || true; \
	helm repo add bitnami https://charts.bitnami.com/bitnami || true; \
	helm repo add jetstack https://charts.jetstack.io || true; \
	helm repo add community-charts https://community-charts.github.io/helm-charts || true; \
	helm repo add external-secrets https://charts.external-secrets.io || true; \
		helm repo add ory https://k8s.ory.sh/helm/charts || true; \
		helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests || true; \
		helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true; \
			helm repo update; \
	fi

install-foundation +args='*':
	# Wrapper to install namespaces, ESO, Cilium (unless SKIP_CILIUM=true), MetalLB, Vault, ArgoCD
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	just --set INSTALL_DRY_RUN "$DRY" helm-repos; \
	INSTALL_DRY_RUN="$DRY" bash tools/scripts/install_foundation.sh

configure-network +args='*':
	# Detect default IPv4 and write deploy/metallb/ipaddresspool.yaml
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] python3 tools/scripts/configure_network.py"; \
	else \
		python3 tools/scripts/configure_network.py; \
	fi

vault-init +args='*':
	# One-click Vault init/unseal and VAULT_TOKEN helper
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	INSTALL_DRY_RUN="$DRY" bash tools/scripts/vault_init.sh

sso-bootstrap +args='*':
	# Install Ory stack, oauth2-proxy(+Redis), onboard Vault K8s auth, and register Hydra clients
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	just --set INSTALL_DRY_RUN "$DRY" helm-repos; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] bash tools/scripts/vault_k8s_onboard.sh"; \
		echo "[dry-run] python3 tools/scripts/hydra_clients.py"; \
	else \
		bash tools/scripts/vault_k8s_onboard.sh || true; \
		python3 tools/scripts/hydra_clients.py || true; \
	fi


deploy-obs +args='*':
	# Support INSTALL_DRY_RUN=1 to print actions instead of performing changes.
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	just --set INSTALL_DRY_RUN "$DRY" helm-repos; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n \"$NAMESPACE_OBS\" -f deploy/observability/otel-values.yaml"; \
		echo "[dry-run] helm upgrade --install loki grafana/loki -n \"$NAMESPACE_OBS\" -f deploy/observability/loki-values.yaml"; \
		echo "[dry-run] helm upgrade --install tempo grafana/tempo -n \"$NAMESPACE_OBS\" -f deploy/observability/tempo-values.yaml"; \
		echo "[dry-run] helm upgrade --install mimir grafana/mimir-distributed -n \"$NAMESPACE_OBS\" -f deploy/observability/mimir-values.yaml"; \
		echo "[dry-run] helm upgrade --install grafana grafana/grafana -n \"$NAMESPACE_OBS\" -f deploy/observability/grafana-values.yaml"; \
		if [ "${PROMTAIL_ENABLED}" = "1" ]; then \
		  echo "[dry-run] helm upgrade --install promtail grafana/promtail -n \"$NAMESPACE_OBS\" -f deploy/observability/promtail-values.yaml"; \
		else \
		  echo "[dry-run] [skipped] promtail disabled (set PROMTAIL_ENABLED=1 to enable)"; \
		fi; \
	else \
		helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n "$NAMESPACE_OBS" -f deploy/observability/otel-values.yaml; \
		helm upgrade --install loki grafana/loki -n "$NAMESPACE_OBS" -f deploy/observability/loki-values.yaml; \
		helm upgrade --install tempo grafana/tempo -n "$NAMESPACE_OBS" -f deploy/observability/tempo-values.yaml; \
		helm upgrade --install mimir grafana/mimir-distributed -n "$NAMESPACE_OBS" -f deploy/observability/mimir-values.yaml || true; \
		helm upgrade --install grafana grafana/grafana -n "$NAMESPACE_OBS" -f deploy/observability/grafana-values.yaml; \
		if [ "${PROMTAIL_ENABLED}" = "1" ]; then \
		  helm upgrade --install promtail grafana/promtail -n "$NAMESPACE_OBS" -f deploy/observability/promtail-values.yaml; \
		else \
		  echo "[skip] promtail disabled (set PROMTAIL_ENABLED=1 to enable)"; \
		fi; \
	fi

deploy-ux +args='*':
	# Support INSTALL_DRY_RUN=1 to print actions instead of performing changes.
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ "$DRY" = "1" ]; then \
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

gitops +args='*':
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] kubectl apply -n argocd -f deploy/argocd/app-of-apps.yaml --dry-run=client"; \
	else \
		kubectl apply -n argocd -f deploy/argocd/app-of-apps.yaml || true; \
	fi

deploy-core +args='*':
	# Delegated deploy logic moved to wrapper script to avoid Justfile multiline fragility
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	just --set INSTALL_DRY_RUN "$DRY" helm-repos; \
	INSTALL_DRY_RUN="$DRY" bash tools/scripts/deploy_core.sh

# Check node open-files limit inside a short-lived pod in the observability namespace
promtail-check +args='*':
	NS="$NAMESPACE_OBS"; NAME="promtail-ulimit-check"; \
	kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"; \
	kubectl -n "$NS" delete pod "$NAME" --ignore-not-found >/dev/null 2>&1 || true; \
	kubectl -n "$NS" run "$NAME" --image=busybox:1.36 --restart=Never --command -- sh -c 'cat /proc/self/limits | grep -i "open files" || true; sleep 8' >/dev/null; \
	for i in $(seq 1 12); do \
	  LOGS=$(kubectl -n "$NS" logs "$NAME" 2>/dev/null || true); [ -n "$LOGS" ] && break; \
	  sleep 1; \
	done; \
	printf "\n[ulimit] %s\n\n" "${LOGS:-'(no output)'}"; \
	kubectl -n "$NS" delete pod "$NAME" --ignore-not-found >/dev/null 2>&1 || true; \
	echo "Tip: Aim for Max open files >= 1048576. See docs/diataxis/guide-promtail-ulimit.md";
audit +args='*':
	# Environment and cluster readiness checks; writes tools/audit/reports/
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] python3 tools/audit/audit_readiness.py (skip writing reports)"; \
	else \
		python3 tools/audit/audit_readiness.py; \
	fi
doctor +args='*':
	# Run audit and surface summary; supports --dry-run
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	just --set INSTALL_DRY_RUN "$DRY" audit

cloudflare-tunnel +args='*':
	# Apply Cloudflare Tunnel (Named Tunnel) manifests; requires credentials secret
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] kubectl apply -n infra -f deploy/cloudflared/config.yaml"; \
		echo "[dry-run] kubectl apply -n infra -f deploy/cloudflared/deployment.yaml"; \
	else \
		kubectl get ns infra >/dev/null 2>&1 || kubectl create ns infra; \
		if ! kubectl -n infra get secret cloudflared-credentials >/dev/null 2>&1; then \
			echo "[error] Missing secret infra/cloudflared-credentials (credentials.json). See docs/diataxis/guide-cloudflare-tunnel.md"; exit 1; \
		fi; \
		kubectl apply -n infra -f deploy/cloudflared/config.yaml; \
		kubectl apply -n infra -f deploy/cloudflared/deployment.yaml; \
	fi

# Helper: Create or update infra/cloudflared-credentials from a credentials.json file
# Usage:
#   just cloudflare-tunnel-secret /absolute/path/to/credentials.json
#   # or place file at tools/secrets/cloudflared/credentials.json and run without args
cloudflare-tunnel-secret +args='*':
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	CRED_PATH=""; for a in {{args}}; do case "$a" in /*.json|/*.JSON) CRED_PATH="$a" ;; esac; done; \
	if [ -z "$CRED_PATH" ]; then \
		CRED_PATH="tools/secrets/cloudflared/credentials.json"; \
	fi; \
	if [ ! -f "$CRED_PATH" ]; then \
		echo "[error] credentials.json not found at '$CRED_PATH'. Download from Cloudflare Zero Trust (Named Tunnel) and try again."; exit 1; \
	fi; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] kubectl get ns infra >/dev/null 2>&1 || kubectl create ns infra"; \
		echo "[dry-run] kubectl -n infra create secret generic cloudflared-credentials --from-file=credentials.json=$CRED_PATH --dry-run=client -o yaml | kubectl apply -f -"; \
	else \
		kubectl get ns infra >/dev/null 2>&1 || kubectl create ns infra; \
		kubectl -n infra create secret generic cloudflared-credentials --from-file=credentials.json="$CRED_PATH" --dry-run=client -o yaml | kubectl apply -f -; \
		echo "[ok] Updated secret infra/cloudflared-credentials from $CRED_PATH"; \
	fi

# Helper: Set/replace the Tunnel UUID in deploy/cloudflared/config.yaml
# Usage: just cloudflare-set-tunnel-id TUNNEL_UUID
cloudflare-set-tunnel-id TUNNEL_ID:
	if [ -z "{{TUNNEL_ID}}" ]; then echo "[error] Provide the Tunnel UUID: just cloudflare-set-tunnel-id <uuid>"; exit 1; fi; \
	if ! grep -q "TUNNEL_ID_PLACEHOLDER" deploy/cloudflared/config.yaml && ! grep -q "tunnel: {{TUNNEL_ID}}" deploy/cloudflared/config.yaml; then \
		echo "[warn] Placeholder not found; showing current 'tunnel:' line:"; \
		grep -n "^\s*tunnel:" -n deploy/cloudflared/config.yaml || true; \
		printf "[info] Not changing file since placeholder is absent.\n"; \
		exit 0; \
	fi; \
	sed -i.bak "s/TUNNEL_ID_PLACEHOLDER/{{TUNNEL_ID}}/g" deploy/cloudflared/config.yaml; \
	rm -f deploy/cloudflared/config.yaml.bak; \
	echo "[ok] Set Tunnel ID in deploy/cloudflared/config.yaml"

cf-dns-secret +args='*':
	# Create/patch cert-manager/cloudflare-api-token-secret from CF_API_TOKEN; supports --dry-run
	DRY=0; for a in {{args}}; do [ "$a" = "--dry-run" ] || [ "$a" = "-n" ] && DRY=1; done; \
	if [ -z "${CF_API_TOKEN:-}" ]; then \
		echo "[error] CF_API_TOKEN is not set. Put it in tools/secrets/.envrc.cloudflare (export CF_API_TOKEN=...) and 'direnv allow .' or export it in your shell."; exit 1; \
	fi; \
	if [ "$DRY" = "1" ]; then \
		echo "[dry-run] kubectl create namespace cert-manager || true"; \
		echo "[dry-run] kubectl -n cert-manager create secret generic cloudflare-api-token-secret --from-literal=api-token=\"$CF_API_TOKEN\" --dry-run=client -o yaml | kubectl apply -f -"; \
	else \
		kubectl get ns cert-manager >/dev/null 2>&1 || kubectl create namespace cert-manager; \
		kubectl -n cert-manager create secret generic cloudflare-api-token-secret --from-literal=api-token="$CF_API_TOKEN" --dry-run=client -o yaml | kubectl apply -f -; \
		echo "[ok] Updated secret cert-manager/cloudflare-api-token-secret"; \
	fi
