# Explanation: System Architecture (High-Level)

Overview
- Kubernetes-first homelab with declarative manifests and Helm charts, orchestrated by `just` recipes.
- Local DNS/TLS via Traefik + cert-manager; optional public access via Cloudflare Tunnel.
- Secrets via Vault (+ External Secrets Operator). Optional SSO via Ory (Hydra/Kratos) + oauth2-proxy.
- Observability via Loki/Tempo/Mimir, visualized in Grafana; pipelines via OTel Collector.

Networking
- CNI: Cilium by default (can skip to keep existing).
- Load balancing: MetalLB with a LAN IP pool.
- Ingress: Traefik (class `traefik`), TLS via cert-manager (local wildcard and public Issuer when configured).

Secrets and identity
- Vault as the primary secret backend; ESO syncs Vault KV to Kubernetes Secrets.
- Ory Hydra (OAuth2/OIDC) + Kratos (identity) support app logins via oauth2-proxy.

Observability
- Loki in SingleBinary mode with filesystem storage: simple, no object store required.
- Tempo for traces; Mimir for metrics. Grafana queries all backends.
- OTel Collector receives OTLP and forwards traces to Tempo; logs are shipped via Promtail (when enabled).

GitOps (optional)
- Argo CD App-of-Apps can reconcile selected stacks from this repo.

Environments and domains
- Local domain `homelab.lan` is the default; edit via `DOMAIN`.
- Public domain (example: `primefam.cloud`) is integrated via Cloudflare Tunnel and public Ingress manifests.

Why SingleBinary Loki?
- For small/medium homelabs without object storage, SingleBinary reduces moving parts while keeping performance acceptable. Caches and SSD roles are disabled to avoid unnecessary complexity.

Why Promtail gating?
- Container ulimits vary across local distros; gating Promtail prevents CrashLoopBackOff until `nofile` limits are raised. See the ulimit guide for details.
