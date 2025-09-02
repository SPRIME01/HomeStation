# Reference: Justfile Recipes

This is a quick reference of the most useful `just` commands. Run with `--dry-run` to preview where supported.

Core
- `just doctor`: Runs environment and cluster readiness checks.
- `just helm-repos [--dry-run]`: Adds/updates helm repos using a minimal registry config.
- `just configure-network`: Detects host/LAN settings and proposes a MetalLB pool. Set `WRITE_METALLB=1` to apply.

Foundation
- `just install-foundation [--dry-run]`: Installs namespaces, cert-manager, ESO, CNI (Cilium unless `SKIP_CILIUM=true`), MetalLB, Vault, ArgoCD.
- `just vault-init`: One-click Vault initialize/unseal and helper token setup.
- `just sso-bootstrap [--dry-run]`: Onboards Vault k8s auth and registers Ory Hydra clients.

Deployments
- `just deploy-core [--dry-run]`: Deploys core apps (Traefik middleware, n8n, RabbitMQ, Flagsmith). Reads manifests/values in `deploy/`.
- `just deploy-obs [--dry-run]`: Deploys Grafana, Loki (SingleBinary), Tempo, Mimir, and OTel Collector.
  - Control logs collection: `PROMTAIL_ENABLED=1` to enable Promtail; default is 0.
- `just deploy-ux [--dry-run]`: Installs UX bundle (Homepage and sample UIs if present).
- `just gitops [--dry-run]`: Applies ArgoCD App-of-Apps (`deploy/argocd/app-of-apps.yaml`).

Cloudflare tunnel
- `just cloudflare-tunnel [--dry-run]`: Applies tunnel Deployment/Config.
- `just cloudflare-tunnel-secret <path/to/credentials.json>`: Creates/updates `infra/cloudflared-credentials` from a file.

Audit
- `just audit [--dry-run]`: Runs environment/cluster audits (writes reports when not dry-run).

Helpers
- `just promtail-check`: Prints the current “Max open files” limit from a short-lived pod in `observability`.

Variables you can set
- `DOMAIN=homelab.lan` (local DNS suffix)
- `NAMESPACE_*` (e.g., `NAMESPACE_OBS=observability`)
- `SKIP_CILIUM=true` (keep existing CNI)
- `PROMTAIL_ENABLED=1` (enable Promtail deploy)
- `WRITE_METALLB=1` (apply generated MetalLB pool)
