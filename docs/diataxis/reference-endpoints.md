# Reference: Endpoints and URLs

This page lists UI endpoints and internal service addresses. Replace `<DOMAIN>` with your configured domain (`DOMAIN`, default `homelab.lan`). Public entries use the example `primefam.cloud` where applicable.

Core UIs (local DNS/TLS)
- Grafana: https://grafana.<DOMAIN>
  - Default admin password (demo): `admin` (see `deploy/observability/grafana-values.yaml:1`)
- n8n: https://n8n.<DOMAIN>
- RabbitMQ: https://rabbitmq.<DOMAIN>
- Flagsmith: https://flagsmith.<DOMAIN>

Public UIs (Cloudflare Tunnel, optional)
- n8n: https://n8n.primefam.cloud
- RabbitMQ: https://rabbitmq.primefam.cloud
- Flagsmith: https://flagsmith.primefam.cloud
- Configure additional hosts: see `docs/diataxis/howto-public-hosts.md` and `docs/diataxis/guide-cloudflare-tunnel.md`.

Observability service addresses (in-cluster)
- Loki gateway (HTTP push): http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push
- Tempo (OTLP gRPC): tempo.observability.svc.cluster.local:4317
- Mimir (read): http://mimir-nginx.observability.svc.cluster.local/prometheus
- Mimir (remote_write): http://mimir-nginx.observability.svc.cluster.local/api/v1/push

SSO and Identity (in-cluster)
- Ory Hydra Admin API: http://hydra-admin.sso.svc.cluster.local:4445
- Ory Kratos Public API: http://kratos-public.sso.svc.cluster.local:4433

Argo CD (optional)
- If installed and exposed via Ingress, use that URL.
- Otherwise, port-forward:
  - `kubectl port-forward -n argocd svc/argocd-server 8080:80` → http://127.0.0.1:8080

Traefik (ingress class)
- IngressClass: `traefik`
- Public entrypoints (when used): `web, websecure`

Verification tips
- DNS: ensure `<host>.<DOMAIN>` resolves to a MetalLB IP within your LAN range.
- TLS: cert-manager should provision `wildcard-<domain>-tls` (local) and Cloudflare/Let’s Encrypt secrets (public), per manifests.
- Cluster-only addresses are not accessible externally; consume via internal services or port-forward.
