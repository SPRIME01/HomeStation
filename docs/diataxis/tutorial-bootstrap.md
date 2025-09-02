# Tutorial: Bootstrap Homestation (Start Here)

This tutorial takes you from a fresh workstation/cluster to a working homelab with networking, secrets, SSO, apps, and observability.

Prerequisites
- A working Kubernetes cluster and `kubectl` context (e.g., Rancher Desktop or k3s)
- Tools: `helm`, `kubectl`, `just`, `bash`
- Optional public access: Cloudflare Zero Trust + a domain (e.g., primefam.cloud)

Key Defaults
- Local domain: `DOMAIN=homelab.lan`
- Namespaces: `core`, `infra`, `observability`, `sso`
- MetalLB pool: `192.168.1.240-192.168.1.250` (customize as needed)

1) Quick environment check
```bash
just doctor
```
Expected: a summary of readiness; if issues, see Troubleshooting.

2) Configure networking (MetalLB auto-detect helper)
```bash
just configure-network
```
This detects host IPs and proposes a safe MetalLB range. To apply the generated pool:
```bash
WRITE_METALLB=1 just configure-network
```

3) Install foundation (CNI, cert-manager, Vault, ESO, ArgoCD, etc.)
```bash
just install-foundation
```
Notes
- If you’re on an existing flannel-based cluster and want to defer Cilium, set `SKIP_CILIUM=true`.
- Foundation will set up core controllers and issuers for TLS.

4) Initialize and unseal Vault (one-click)
```bash
just vault-init
```
This initializes + unseals Vault and makes a session token available to subsequent steps.

5) Bootstrap SSO and clients
```bash
just sso-bootstrap
```
This onboards Kubernetes auth with Vault (if enabled) and registers Ory Hydra clients for OAuth flows.

6) Deploy core apps
```bash
just deploy-core
```
Installs Traefik middleware and core apps (n8n, RabbitMQ, Flagsmith manifests, etc.).

7) Deploy Observability
```bash
# Safe preview
just deploy-obs --dry-run
# Apply
just deploy-obs
```
Included:
- Loki (SingleBinary + filesystem)
- Tempo
- Mimir (demo/default settings)
- Grafana (with Ingress)
- OpenTelemetry Collector (traces → Tempo)

Logs collection (best practice)
- Promtail is included but disabled by default: `PROMTAIL_ENABLED=0`.
- First, raise node file-descriptor limits (ulimit). See `docs/diataxis/guide-promtail-ulimit.md`.
- Enable when ready:
```bash
PROMTAIL_ENABLED=1 just deploy-obs
```
Verify limits quickly:
```bash
just promtail-check
```

8) Deploy UX bundle (optional)
```bash
just deploy-ux
```
Installs UI helpers (Homepage), plus sample manifests (Guacamole, Vaultwarden, etc.) if present.

9) Optional: GitOps umbrella
```bash
just gitops
```
Applies ArgoCD App-of-Apps to manage selected components from this repo.

What’s next
- Reference endpoints and credentials: `docs/diataxis/reference-endpoints.md`
- How-to expose public UIs via Cloudflare Tunnel: `docs/diataxis/guide-cloudflare-tunnel.md`
- Troubleshooting common issues: `docs/diataxis/troubleshooting.md`
