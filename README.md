# Homelab Scaffold (Nx + Just, SSO + Redis, Vault + ESO, ArgoCD)

Idempotent scaffold using Helm + kubectl apply. Cluster-first (Traefik + DNS + MetalLB).

## Quickstart

### Network auto-config
Run this first to detect your host IP and safely pick a MetalLB pool in your LAN:
```bash
just configure-network
```

1) `just doctor`
2) `just install-foundation` (sets up MetalLB, cert-manager, Vault, ArgoCD; keeps flannel)
4) `just vault-init` (one-click init/unseal + VAULT_TOKEN helper)
5) `just sso-bootstrap`
6) `just deploy-core && just deploy-obs && just deploy-ux`
7) `pnpm i && pnpm nx g @org/nx-homelab-plugin:service my-api`

> If `hydra_clients.py` reads YAML, install: `python3 -m pip install pyyaml`.

### CNI choice
Default is flannel (no Cilium). You can experiment with Cilium later; see `docs/rancher-desktop-config.md`.

If you're on Rancher Desktop and hit a CNI path error (kubelet expecting `/usr/libexec/cni`), see `docs/rancher-desktop-cilium.md`. You can also force our installer to target that path via:
```bash
export CILIUM_CNI_BIN_PATH=/usr/libexec/cni
export CILIUM_CNI_CONF_PATH=/etc/cni/net.d
just install-foundation
```

### Vault one-click helper
Initialize/unseal Vault and set a session token (optionally write `tools/secrets/.envrc.vault` and have `.envrc` source it):
```bash
just vault-init
# then:
just sso-bootstrap

### TLS via Traefik (local CA)
`install-foundation` installs cert-manager and bootstraps a local CA. A wildcard `*.homelab.lan` certificate is issued for the `core` namespace and used by Ingresses.

Trust the CA on your workstation to remove browser warnings:
```bash
kubectl -n cert-manager get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
# Import homelab-ca.crt into your OS/browser trust store
```

### Public TLS via Cloudflare (primefam.cloud)
If your domain is on Cloudflare, you can issue Let's Encrypt certificates with DNS-01 and expose selected apps publicly.

1) Create an API token on Cloudflare with Zone.DNS:Edit for `primefam.cloud`.
2) Create the secret (once):
```bash
kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
  --from-literal=api-token='<CF_API_TOKEN>'
```
3) Set env vars and run foundation:
```bash
export TLS_PUBLIC_DOMAIN=primefam.cloud
export ACME_EMAIL=sprime01@gmail.com
just install-foundation
```
4) Public hostnames are provided via `deploy/*/ingress-public.yaml` and use the wildcard secret `wildcard-primefam-cloud-tls`.
   - `n8n.primefam.cloud`, `rabbitmq.primefam.cloud`, `flagsmith.primefam.cloud`

Networking options:
- Port-forward 80/443 from your router to Traefik’s MetalLB IP, or
- Use Cloudflare Tunnel (no port-forward). If you prefer Tunnel, say the word and I’ll add a `cloudflared` deployment and routes.

If you chose to write the session file, ensure your `.envrc` contains:

```
source_env_if_exists tools/secrets/.envrc.vault
```
```
