# Homestation Homelab – Technical Documentation

## Project Overview

- Name: Homestation Homelab
- Description: A homelab scaffold for a k3s/Kubernetes cluster providing idempotent, one‑click operations, SSO, secret management, L2 load balancing, observability, and core applications (RabbitMQ, n8n, Flagsmith, etc.). Local-first TLS with a private CA, and optional public access via Cloudflare with Let’s Encrypt (DNS‑01) and Cloudflare Tunnel.
- Technologies:
  - Kubernetes (k3s), Helm, kubectl, MetalLB, Traefik (Ingress)
  - Vault + External Secrets Operator (ESO)
  - Ory Hydra/Kratos + oauth2-proxy (SSO)
  - Observability: OpenTelemetry Collector, Loki, Tempo, Grafana
  - Core apps: RabbitMQ, n8n (Community Helm chart), Flagsmith
  - Nx plugin for FastAPI services generation
  - direnv for environment loading (.envrc)
- Architecture overview:
  - Namespaces: infra, sso, core, observability
  - Local TLS: cert-manager issues a wildcard certificate for *.homelab.lan using a cluster-local CA
  - Public TLS: Let’s Encrypt via DNS‑01 (Cloudflare) issues wildcard for *.primefam.cloud
  - Ingress: Traefik handles internal and public routes
  - Public access: Cloudflare Tunnel routes primefam.cloud hosts to Traefik without router port-forward
  - Secrets: Vault KV v2 + ESO; workloads consume via ExternalSecret
  - SSO: Ory stack with oauth2-proxy; Hydra clients auto-registered

## System Requirements

- Software:
  - Node ≥ 18 (tested with Node 20+), pnpm ≥ 9
  - Python ≥ 3.10
  - kubectl, helm 3.x, docker/container runtime
  - vault CLI
  - Optional: argocd CLI, sops, age
- Kubernetes:
  - CNI: flannel (Cilium disabled/scrubbed)
  - MetalLB for L2 LoadBalancer IPs
- Host considerations:
  - If WSL2, enable systemd to avoid service issues.

## Installation & Setup

### Prerequisites

- Install toolchain (Node, pnpm, kubectl, helm, docker, vault).
- Clone repository and bootstrap dependencies:
```bash
pnpm install
```

- Configure direnv to load environment:
  - .envrc sources:
    - tools/secrets/.envrc.vault (Vault session; optional, written by vault-init)
    - tools/secrets/.envrc.cloudflare (Cloudflare DNS token; optional)
  - Enable direnv:
```bash
# For zsh
eval "$(direnv hook zsh)"
direnv allow .
direnv reload
```

### Network autodetect (MetalLB pool)
```bash
just configure-network
```

### Foundation (cert-manager, CA, MetalLB, ESO, Vault, Argo CD; flannel CNI)
- Dry-run then apply:
```bash
just install-foundation --dry-run
just install-foundation
```

### Vault init/unseal
```bash
just vault-init
# If prompted, allow writing tools/secrets/.envrc.vault
direnv reload
echo ${VAULT_TOKEN:+set}  # should print "set"
```

### Public TLS (Cloudflare DNS‑01; domain: primefam.cloud)
- Create Cloudflare DNS token and load via direnv:
```bash
# Put token in a local direnv secrets file (untracked)
echo 'export CF_API_TOKEN=YOUR_CF_DNS_TOKEN' > tools/secrets/.envrc.cloudflare
direnv reload
```
- Create/patch the Kubernetes secret (idempotent):
```bash
just cf-dns-secret --dry-run
just cf-dns-secret
```
- Export and apply ACME config:
```bash
export TLS_PUBLIC_DOMAIN=primefam.cloud
export ACME_EMAIL=sprime01@gmail.com
just install-foundation --dry-run
just install-foundation
```

### Cloudflare Tunnel (public access without router ports)
- Create a Named Tunnel in Cloudflare Zero Trust, note Tunnel UUID, download credentials.json.
- Create secret:
```bash
kubectl -n infra create secret generic cloudflared-credentials \
  --from-file=credentials.json=/path/to/credentials.json
```
- Edit deploy/cloudflared/config.yaml to set your Tunnel UUID.
- Deploy:
```bash
just cloudflare-tunnel --dry-run
just cloudflare-tunnel
```

## Configuration

### Environment variables
- Loaded via direnv (.envrc):
  - VAULT_TOKEN from tools/secrets/.envrc.vault (optional)
  - CF_API_TOKEN from tools/secrets/.envrc.cloudflare (for DNS‑01 secret creation)
  - TLS_PUBLIC_DOMAIN (e.g., primefam.cloud)
  - ACME_EMAIL (ACME registration email)

### TLS and cert-manager
- Local CA:
  - Issues wildcard certificate for *.homelab.lan
  - Trust the CA locally to avoid browser warnings:
```bash
kubectl -n cert-manager get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
# Import homelab-ca.crt into your OS/browser trust store
```
- Public ACME (Cloudflare DNS‑01):
  - ClusterIssuer uses cert-manager secret: cert-manager/cloudflare-api-token-secret
  - Issues wildcard for *.primefam.cloud

### Ingress
- Traefik is the default Ingress controller for UIs.
- Local hosts:
  - n8n.homelab.lan, rabbitmq.homelab.lan, flagsmith.homelab.lan (TLS via local CA)
- Public hosts (via Cloudflare Tunnel):
  - n8n.primefam.cloud, rabbitmq.primefam.cloud, flagsmith.primefam.cloud (TLS via Let’s Encrypt)

### n8n (Community Helm Chart v1.15.2)
- Chart: community-charts/n8n
- Values file: deploy/n8n/community-values.yaml
  - Uses correct keys per community chart (e.g., main.persistence, main.extraEnvVars)
  - Sets N8N_HOST=n8n.primefam.cloud, N8N_PROTOCOL=https
- Edge auth: Traefik BasicAuth middleware (optional)
  - Secret: core/n8n-basicauth (users key: htpasswd format)
  - Referenced by n8n Ingresses

### RabbitMQ
- AMQP is cluster-internal (rabbitmq.core.svc.cluster.local:5672)
- Management UI exposed via Traefik Ingress (local and public)

## Code Implementation

- File structure highlights:
  - deploy/cert-manager/
    - bootstrap-ca.yaml
    - wildcard-certificate.yaml
    - issuer-cloudflare.yaml
    - wildcard-primefam-cloud.yaml
  - deploy/cloudflared/
    - config.yaml (set Tunnel UUID)
    - deployment.yaml
  - deploy/n8n/
    - community-values.yaml (community chart schema)
    - ingress.yaml (local)
    - ingress-public.yaml (public)
    - traefik/n8n-auth-middleware.yaml
  - deploy/rabbitmq/
    - ingress.yaml (local)
    - ingress-public.yaml (public)
  - deploy/flagsmith/
    - deploy.yaml (Ingress + TLS updates)
    - ingress-public.yaml (public)
  - tools/scripts/ (install/deploy helpers)
  - Justfile (recipes with global --dry-run support)

- Critical behaviors:
  - All Just recipes accept --dry-run/-n; INSTALL_DRY_RUN is optional and auto-set.
  - Just recipes ensure Helm repo setup without requiring OS keyrings (safe defaults).

## Commands Reference

- Workspace bootstrap:
```bash
pnpm install
```

- Network pool detection:
```bash
just configure-network --dry-run
just configure-network
```

- Foundation (idempotent):
```bash
just install-foundation --dry-run
just install-foundation
```

- Vault initialize/unseal:
```bash
just vault-init
direnv reload
```

- SSO + Vault K8s onboarding + Hydra clients:
```bash
just sso-bootstrap --dry-run
just sso-bootstrap
```

- Create Cloudflare DNS token secret:
```bash
# Place token in tools/secrets/.envrc.cloudflare, then:
just cf-dns-secret --dry-run
just cf-dns-secret
```

- Core apps (n8n community chart, RabbitMQ, Flagsmith, Ingress):
```bash
just deploy-core --dry-run
just deploy-core
```

- Cloudflare Tunnel:
```bash
just cloudflare-tunnel --dry-run
just cloudflare-tunnel
```

- Observability stack:
```bash
just deploy-obs --dry-run
just deploy-obs
```

- UX apps:
```bash
just deploy-ux --dry-run
just deploy-ux
```

- Doctor:
```bash
just doctor
```

## Troubleshooting Guide

- cert-manager namespace missing:
  - Symptom: error: failed to create secret namespaces "cert-manager" not found
  - Fix: Run foundation first or create ns:
```bash
just install-foundation
# or
kubectl create namespace cert-manager
```

- VAULT_TOKEN not set after vault-init:
  - Ensure direnv is hooked; reload:
```bash
eval "$(direnv hook zsh)"  # or bash
direnv allow .
direnv reload
echo ${VAULT_TOKEN:+set}
```

- n8n chart schema errors:
  - Cause: Using Bitnami values against Community chart.
  - Fix: Use deploy/n8n/community-values.yaml (community schema) and community chart v1.15.2.

- Docker/helm secretservice helper errors (OCI auth prompts):
  - Avoid by using community charts or HTTPS charts; current setup uses community chart for n8n and avoids secretservice.

- Public TLS not issuing:
  - Ensure the Cloudflare DNS token secret exists:
```bash
kubectl -n cert-manager get secret cloudflare-api-token-secret
```
  - Ensure TLS_PUBLIC_DOMAIN and ACME_EMAIL are exported and foundation rerun.

- Tunnel not routing:
  - Check deployment readiness and logs:
```bash
kubectl -n infra rollout status deploy/cloudflared
kubectl -n infra logs deploy/cloudflared -f
```
  - Verify Tunnel UUID in deploy/cloudflared/config.yaml and credentials.json secret.

## Deployment & Operations

- Deployment order (always dry-run first):
  1) just install-foundation --dry-run && just install-foundation
  2) export TLS_PUBLIC_DOMAIN=primefam.cloud; export ACME_EMAIL=sprime01@gmail.com
     - just install-foundation --dry-run && just install-foundation
  3) just deploy-core --dry-run && just deploy-core
  4) just cloudflare-tunnel --dry-run && just cloudflare-tunnel
  5) just deploy-obs --dry-run && just deploy-obs
  6) just deploy-ux --dry-run && just deploy-ux

- Monitoring/Logs:
  - Use kubectl get/describe across core and infra namespaces
  - Grafana/Tempo/Loki via observability stack

- Backup/Recovery:
  - Vault and app data via PVs; plan snapshots externally (not included here)

- Scaling:
  - Adjust replicas in Helm values or Deployments; ensure MetalLB and Traefik capacity

## Additional Notes

- Security:
  - Do not commit secrets; use Vault KV v2 and ESO
  - Use BasicAuth middleware for n8n public exposure
  - Keep Cloudflare API token in tools/secrets/.envrc.cloudflare (gitignored)

- Domains:
  - Local canonical: *.homelab.lan (private CA)
  - Public: *.primefam.cloud (Let’s Encrypt via DNS‑01)

- CNI:
  - Cilium fully scrubbed; flannel is the default and expected

- Future Enhancements:
  - Optional: ACME HTTP‑01 if you move to public ingress IPs
  - Kong alongside Traefik using ingressClassName per route
  - Add mTLS/AMQP TLS fronting for RabbitMQ if external AMQP exposure becomes necessary
