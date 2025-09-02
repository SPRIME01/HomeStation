# Guide: Expose your homelab via Cloudflare Tunnel

This is a step-by-step tutorial to publish selected apps (n8n, RabbitMQ, Flagsmith) under `*.primefam.cloud` without router port-forwarding.

Prerequisites
- Domain `primefam.cloud` on Cloudflare
- `kubectl` connected to your cluster

Steps
1. Create a Named Tunnel in Cloudflare Dashboard
   - Zero Trust → Networks → Tunnels → Create Tunnel → Named Tunnel
   - Note the Tunnel UUID (TUNNEL_ID) and download `credentials.json`
2. Create Kubernetes secret with credentials
   - Option A (recommended): use helper recipe
````markdown
# Cloudflare Tunnel: expose your homelab apps (no port-forwarding)

Publish selected apps (e.g., n8n, RabbitMQ, Flagsmith) under your domain (example: `*.primefam.cloud`) using a Cloudflare Named Tunnel. No router/firewall changes needed.

## Prerequisites
- A domain managed by Cloudflare (replace `primefam.cloud` with your domain)
- Cloudflare Zero Trust enabled (free plan is fine)
- `kubectl` connected to your cluster
- Optional: `cloudflared` CLI if you prefer CLI instead of the Dashboard

## Repo wiring
- Manifests in `deploy/cloudflared/`:
  - `config.yaml`: ConfigMap with your Tunnel UUID (tunnel:) and in-pod ingress rules to Traefik (`kube-system/traefik:80`).
  - `deployment.yaml`: runs the connector and mounts secret `infra/cloudflared-credentials` as `/etc/cloudflared/credentials/credentials.json`.
- Helper Just recipes:
  - `cloudflare-tunnel-secret` – create/update the credentials secret
  - `cloudflare-set-tunnel-id` – patch Tunnel UUID in the config
  - `cloudflare-tunnel` – apply manifests

## Steps
1) Create a Named Tunnel and download credentials.json
   - Dashboard: Zero Trust → Networks → Tunnels → Create Tunnel → Named Tunnel. Note the Tunnel UUID and download `credentials.json`.
   - CLI (optional):
```bash
cloudflared tunnel login
cloudflared tunnel create homestation
cloudflared tunnel list   # get the Tunnel UUID
# credentials file at ~/.cloudflared/<TUNNEL_UUID>.json
```

2) Create the Kubernetes secret
```bash
# Recommended (helper):
just cloudflare-tunnel-secret /absolute/path/to/credentials.json

# Or with kubectl directly:
kubectl -n infra create secret generic cloudflared-credentials \
  --from-file=credentials.json=/path/to/credentials.json
```

3) Set the Tunnel UUID
```bash
just cloudflare-set-tunnel-id TUNNEL_UUID
```
Alternative: edit `deploy/cloudflared/config.yaml` and replace `TUNNEL_ID_PLACEHOLDER`.

4) Apply manifests
```bash
just cloudflare-tunnel
```

## Verify
```bash
kubectl -n infra rollout status deploy/cloudflared
kubectl -n infra logs deploy/cloudflared -f | grep -Ei "ready|ingress|connected|connection"
```
Test a hostname you configured (replace with your domain):
```bash
open https://n8n.primefam.cloud
```

## Hostnames and routing
- Recommended: keep `ingress:` rules inside `deploy/cloudflared/config.yaml` aligned with your domain; they route to Traefik.
- Alternative: add Public Hostnames in the Cloudflare Tunnel UI pointing to `http://traefik.kube-system.svc.cluster.local:80`.

## Optional: DNS-01 with cert-manager
Cloudflare Tunnel doesn’t require origin TLS. If you also want cert-manager DNS-01:
```bash
printf "export CF_API_TOKEN='YOUR_TOKEN'\n" > tools/secrets/.envrc.cloudflare
chmod 600 tools/secrets/.envrc.cloudflare
direnv allow .
just cf-dns-secret
```

## Troubleshooting
- Missing secret: `just cloudflare-tunnel-secret /path/to/credentials.json`.
- Tunnel ID not set: `just cloudflare-set-tunnel-id TUNNEL_UUID`.
- 403/404: ensure hostnames in `config.yaml` match your domain and services are reachable via Traefik.
- 502: check Traefik: `kubectl -n kube-system get svc traefik` and app pod health.
- CrashLoop: secret must have key `credentials.json` and a valid file.
- Permissions: if storing the file locally, keep it mode `600`. It’s ignored by `.gitignore`.

## Cleanup
```bash
kubectl -n infra delete deploy cloudflared || true
kubectl -n infra delete configmap cloudflared-config || true
kubectl -n infra delete secret cloudflared-credentials || true
# Delete the Named Tunnel in Cloudflare (Dashboard or CLI)
# cloudflared tunnel delete <TUNNEL_UUID>
```
````

