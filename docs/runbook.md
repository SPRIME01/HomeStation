A short, practical runbook to take the scaffold from “charts applied” to “fully initialized, secrets seeded, TLS/DNS working, and UIs reachable.”

Below is a concise, end‑to‑end path you can run now.

Prereqs

kubectl + helm + docker/container runtime; node ≥ 18 + pnpm; vault CLI.
A working K8s cluster (k3s/Rancher Desktop/etc.) and current kube context set.
Optional: direnv for a smoother experience.
Workspace Setup

Clone/open the repo, then:
pnpm install
cp .env.example .env and adjust non-secrets as needed.
direnv allow . to auto-load .envrc and optional secrets (when created).
1) Configure MetalLB pool

just configure-network to safely pick a pool for your LAN.
This prevents IP conflicts and configures the pool for LoadBalancer services.
2) Install foundation (namespaces, CRDs, core infra)

Flannel users (default path): export SKIP_CILIUM=true
Install: just install-foundation
This installs MetalLB, Vault, External Secrets Operator, Argo CD, and base namespaces.
3) Initialize + unseal Vault, export a session

just vault-init
Choose to write tools/secrets/.envrc.vault (mode 600).
.envrc auto-loads it after direnv allow ..
If you didn’t write the file: source tools/secrets/.envrc.vault
Note: If a valid Vault token already exists (env or ~/.vault-token), vault-init now offers to write tools/secrets/.envrc.vault for persistence.
4) Bootstrap SSO + Vault K8s auth (ESO role)

just sso-bootstrap
This configures Vault’s Kubernetes auth and ESO role “eso”, and registers Ory Hydra clients.
It also ensures a KV v2 secrets engine is enabled at path "kv" (used by ESO and seed scripts).

5) Seed required secrets in Vault (one‑time)

All built-ins: just vault-seed-kv (guided) or just vault-seed-kv --random
Seed one service: just vault-seed-kv --only n8n (or rabbitmq, flagsmith)
New Nx service APP_SECRET: just vault-seed <service> --random
Notes:
- VAULT_TOKEN must be loaded (direnv allow . or source tools/secrets/.envrc.vault).
- VAULT_ADDR defaults to http://127.0.0.1:8200. If targeting localhost and Vault isn’t reachable, vault-seed-kv auto-starts a short-lived kubectl port-forward to infra/vault.
Vault paths seeded:
kv/apps/n8n/app: N8N_BASIC_AUTH_PASSWORD
kv/apps/rabbitmq/app: password, erlangCookie
kv/apps/flagsmith/app: secret-key
kv/apps/flagsmith/database: url (optional; set if you have a DB)
kv/apps/<service>/APP_SECRET: APP_SECRET (Nx generator)
6) Deploy core, observability, UX

Core: just deploy-core
RabbitMQ, n8n, Flagsmith. ESO ExternalSecrets are applied when CRD exists.
Observability: just deploy-obs
OTel Collector, Loki, Tempo, Mimir, Grafana.
Only enable Promtail after raising node ulimit:
Check: just promtail-check
When safe: PROMTAIL_ENABLED=1 just deploy-obs
UX: just deploy-ux
Homepage, Guacamole, Vaultwarden, MCP Context Forge.
7) TLS and DNS options

Local wildcard via cert-manager (default):
Trust local CA on your machine:
kubectl -n cert-manager get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
Import homelab-ca.crt into OS/browser trust store.
DNS for <app>.homelab.lan:
Point your resolver to the MetalLB IP assigned to Traefik, or add /etc/hosts entries mapping <app>.homelab.lan → your MetalLB address.
Optional public TLS via Cloudflare:
Put export CF_API_TOKEN=... into tools/secrets/.envrc.cloudflare and direnv allow .
export TLS_PUBLIC_DOMAIN=yourdomain.tld
export ACME_EMAIL=you@example.com
just cf-dns-secret
just install-foundation (applies public issuers/wildcard)
Public ingress samples are provided (e.g., n8n/flagsmith/rabbitmq).
8) Verify

ESO sync: kubectl -n core get externalsecret,secret | grep -E 'n8n|rabbitmq|flagsmith'
Ingress: kubectl -n core get ingress
UIs (default domain homelab.lan):
Grafana: https://grafana.homelab.lan (admin/admin initially; change after login)
n8n: https://n8n.homelab.lan (Basic Auth user admin, password from Vault seed)
RabbitMQ: https://rabbitmq.homelab.lan (user user, password from Vault seed)
Flagsmith: https://flagsmith.homelab.lan
Health checks:
just doctor for environment and cluster readiness.
kubectl -n core get pods, kubectl -n observability get pods report ready states.
Common Pitfalls

ESO resources Pending: ensure VAULT_TOKEN valid, just sso-bootstrap ran, and ClusterSecretStore vault-kv exists.
TLS warnings: import the local CA (homelab-ca.crt) as above, or use Cloudflare/public TLS.
n8n password not accepted: confirm n8n-env Secret exists and chart is consuming it:
Bitnami: extraEnvVarsSecret: n8n-env in deploy/n8n/values.yaml
Community: envFrom.secretRef: n8n-env in deploy/n8n/community-values.yaml


Check your current cluster IPs and generate /etc/hosts entries for the key UIs.

Configure the Cloudflare public path end-to-end (tunnel or DNS-01) based on your domain.

Hosts Entries (if not using DNS)
- Determine Traefik LoadBalancer IP (EXTERNAL-IP of kube-system svc/traefik):
  - kubectl -n kube-system get svc traefik -o wide
- Add to /etc/hosts (replace <TRAEFIK_LB_IP> and <DOMAIN>):
  <TRAEFIK_LB_IP> grafana.<DOMAIN>
  <TRAEFIK_LB_IP> n8n.<DOMAIN>
  <TRAEFIK_LB_IP> rabbitmq.<DOMAIN>
  <TRAEFIK_LB_IP> flagsmith.<DOMAIN>

Information I need from you (to finalize DNS/TLS)
- Your chosen `DOMAIN` (default is `homelab.lan`).
- Do you want local-only TLS (trusted local CA) or public TLS via Cloudflare DNS-01? If Cloudflare, confirm `TLS_PUBLIC_DOMAIN` and that you can set `CF_API_TOKEN`.
- The Traefik LoadBalancer external IP (output of the command above), so I can generate ready-to-paste /etc/hosts lines.
