# Homestation Documentation Index

Welcome. This landing page links the core documentation using the Diátaxis structure (Tutorials, How‑Tos, Reference, Explanations), plus fast paths to UIs and common tasks.

Quick Start
- Tutorial: Bootstrap the homelab end‑to‑end → docs/diataxis/tutorial-bootstrap.md
- Endpoints and URLs (local/public/in‑cluster) → docs/diataxis/reference-endpoints.md
- Justfile recipe reference → docs/diataxis/reference-just-recipes.md

Common Tasks
- Install foundation: `just install-foundation`
- Deploy core apps: `just deploy-core`
- Deploy observability: `just deploy-obs` (preview with `--dry-run`)
- Enable Promtail after raising ulimit: `PROMTAIL_ENABLED=1 just deploy-obs`
- Check node “Max open files”: `just promtail-check`

UIs (defaults)
- Grafana: https://grafana.<DOMAIN>
- n8n: https://n8n.<DOMAIN>
- RabbitMQ: https://rabbitmq.<DOMAIN>
- Flagsmith: https://flagsmith.<DOMAIN>
- Public examples: n8n/flagsmith/rabbitmq on primefam.cloud

Tutorials
- Bootstrap (Start Here) → docs/diataxis/tutorial-bootstrap.md

How‑Tos
- Access UIs (local/public) → docs/diataxis/howto-access-uis.md
- Operate Observability (Grafana/Loki/Tempo/Mimir/OTel) → docs/diataxis/howto-observability.md
- Public hosts via Cloudflare Tunnel → docs/diataxis/howto-public-hosts.md
- Cloudflare Tunnel guide → docs/diataxis/guide-cloudflare-tunnel.md
- Promtail ulimit tuning → docs/diataxis/guide-promtail-ulimit.md

Reference
- Endpoints and URLs → docs/diataxis/reference-endpoints.md
- Justfile recipes → docs/diataxis/reference-just-recipes.md
- Environment variables → docs/diataxis/reference-env-vars.md
- direnv for env/secrets → docs/diataxis/guide-direnv.md

Explanations
- Architecture overview → docs/diataxis/explanation-architecture.md
- TLS architecture → docs/diataxis/explanation-tls-architecture.md

Troubleshooting
- Common issues and fixes → docs/diataxis/troubleshooting.md

Notes
- `<DOMAIN>` defaults to `homelab.lan` (override via `DOMAIN`).
- Ingress class is `traefik`; TLS via cert‑manager (local wildcard and optional public Issuer).
