# Homelab Scaffold (Nx + Just, SSO + Redis, Vault + ESO, ArgoCD)

Idempotent scaffold using Helm + kubectl apply. Cluster-first (Traefik + DNS + MetalLB).

## Quickstart

### Network auto-config
Run this first to detect your host IP and safely pick a MetalLB pool in your LAN:
```bash
just configure-network
```

1) `just doctor`
2) Optionally set `export SKIP_CILIUM=true` (keep flannel for now; migrate later)
3) `just install-foundation`
4) `just vault-init` (one-click init/unseal + VAULT_TOKEN helper)
5) `just sso-bootstrap`
6) `just deploy-core && just deploy-obs && just deploy-ux`
7) `pnpm i && pnpm nx g @org/nx-homelab-plugin:service my-api`

> If `hydra_clients.py` reads YAML, install: `python3 -m pip install pyyaml`.

### CNI choice
By default we install **Cilium**. If your current k3s uses flannel and you want to defer a rebuild, set:
```bash
export SKIP_CILIUM=true
```
before running `just install-foundation`.

### Vault one-click helper
Initialize/unseal Vault and set a session token (optionally write `tools/secrets/.env.vault`):
```bash
just vault-init
# then:
just sso-bootstrap
```
