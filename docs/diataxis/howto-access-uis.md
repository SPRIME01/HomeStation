# How-To: Access the UIs

Local access (`<DOMAIN>`; default: `homelab.lan`)
- Ensure your LAN DNS (or /etc/hosts) resolves `*.homelab.lan` to a MetalLB IP in your pool.
- Visit:
  - Grafana: https://grafana.<DOMAIN>
  - n8n: https://n8n.<DOMAIN>
  - RabbitMQ: https://rabbitmq.<DOMAIN>
  - Flagsmith: https://flagsmith.<DOMAIN>

Public access (Cloudflare)
- Follow `docs/diataxis/guide-cloudflare-tunnel.md` to create `infra/cloudflared-credentials` and configure hostnames.
- Example public hosts (from manifests):
  - https://n8n.primefam.cloud
  - https://rabbitmq.primefam.cloud
  - https://flagsmith.primefam.cloud

TLS
- Local TLS: cert-manager issues wildcard (see `deploy/cert-manager/*`).
- Public TLS: Let’s Encrypt via Cloudflare (annotations in `*-public.yaml`).

Auth
- Some Ingresses use Traefik middlewares (e.g., n8n basic auth) per `deploy/traefik/n8n-auth-middleware.yaml`.
- For full SSO, integrate OAuth2 Proxy with Ory Hydra (see SSO bootstrap step and app-specific annotations/values).

When a UI won’t load
- Check DNS: `dig +short grafana.<DOMAIN>` resolves to a MetalLB IP.
- Check Ingress: `kubectl get ingress -A | rg grafana`
- Check certificate: `kubectl get cert -A | rg homelab`
- Check pods: `kubectl get pods -n observability` (for Grafana) / `-n core` (apps)
- Check Traefik logs: `kubectl logs -n kube-system deploy/traefik` (name may vary per distro)
