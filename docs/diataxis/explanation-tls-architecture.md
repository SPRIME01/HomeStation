# Explanation: TLS architecture (local + public)

Local-first
- cert-manager issues a CA and wildcard certificate for `*.homelab.lan`.
- Traefik terminates TLS using that wildcard; trust the CA on your machine for a warning-free experience.

Public
- cert-manager provisions Let’s Encrypt wildcard for `*.primefam.cloud` via Cloudflare DNS-01.
- Cloudflare Tunnel brings traffic to Traefik (no router port-forward). Cloudflare terminates edge TLS; origin can be HTTP.

Ingress policy
- We manage Ingress in YAML (not via helm values) for clarity and consistency across charts.
- Use Traefik middlewares for authentication and rate limiting when exposing publicly.

Alternatives
- You can switch to Kong for API exposure while keeping Traefik for UI; just set `ingressClassName: kong` for selected routes.
