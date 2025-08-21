# Copilot Coding Agent – Onboarding Instructions

> **Purpose:** Teach the agent how to work effectively in this repo on first sight, so changes **build, deploy, and validate** cleanly without guesswork. If anything here conflicts with ad‑hoc searches, **trust this file first** and only search when something is missing or demonstrably incorrect.

## High‑level summary

* **What this repo is:** A **homelab scaffold** for a k3s/Kubernetes cluster with:

  * **Idempotent one‑click ops** via `Justfile` (Helm + kubectl).
  * **SSO** (Ory Hydra/Kratos + oauth2‑proxy) with optional **Redis** session store.
  * **Vault** + **External Secrets Operator (ESO)** for secret delivery to workloads.
  * **MetalLB** L2 load balancer; **Observability stack** (OTel Collector, Loki, Tempo, Grafana).
  * **Core apps:** RabbitMQ, n8n, Flagsmith, Guacamole, Vaultwarden, MCP Context Forge.
  * **Nx plugin** to generate FastAPI services with k8s manifests + ExternalSecret.
* **Primary languages & tools:**
  TypeScript (Nx plugin), Python (helper scripts & FastAPI services), Bash (ops), Helm charts, Kubernetes YAML.
  Package manager: **pnpm**. Task runner: **just**.

## Toolchain & Versions (expected)

* **Node** ≥ 18 (repo tested with Node 20+), **pnpm** ≥ 9, **Python** ≥ 3.10.
* **kubectl**, **helm** 3.x, **docker** or container runtime available.
* **vault** CLI for Vault tasks.
* (Optional but recommended) **argocd** CLI, **sops**, **age** for future work.

> If on WSL2: enable **systemd** (in `/etc/wsl.conf`) to avoid service issues.

---

## Build/Run/Test – canonical sequences

> **Always run these in this order** to avoid transient failures. Commands are **idempotent** unless noted.

### 0) Bootstrap (workspace)

```bash
pnpm install
```

* Postinstall is minimal; no build step required at this stage.

### 1) Network autodetect (MetalLB pool)

```bash
just configure-network
```

* Detects default IPv4 + `/24` and rewrites `deploy/metallb/ipaddresspool.yaml` to avoid collisions.
* **Always run** after moving hosts or changing NICs/subnets.

### 2) Foundation install (namespaces, CRDs, core infra)

```bash
# If the cluster currently uses flannel and you DO NOT want to install Cilium yet:
export SKIP_CILIUM=true
just install-foundation
```

* Creates namespaces (`infra`, `sso`, `core`, `observability`)
* Installs **MetalLB**, **External Secrets Operator**, **Vault** (Raft, no TLS for internal), **Argo CD**.
* If `SKIP_CILIUM` is unset, the target attempts to install **Cilium** in `kube-system`.

### 3) Vault init/unseal (one‑click helper)

```bash
just vault-init
```

* Starts a **short‑lived port‑forward** to `infra/svc/vault` on `127.0.0.1:8200`.
* If Vault is **uninitialized**, it will:

  * Initialize (1 key share), display **Unseal Key** & **Initial Root Token** (stdout only),
  * **Unseal once**, set `VAULT_TOKEN` for the current process,
  * Optionally write `tools/secrets/.env.vault` (mode 600) if you confirm.
* If already initialized but sealed, prompts for **Unseal Key**.
* If unsealed and no token exported, prompts for a token.

> After this step, you should have `VAULT_TOKEN` available in the current shell. If not: `source tools/secrets/.env.vault` (if created) or export a valid token.

### 4) SSO + Redis + Vault K8s onboarding

```bash
# With VAULT_TOKEN set in the current shell:
just sso-bootstrap
```

* Autodetects LAN again for safety.
* Installs **Kratos**, **Hydra**, **oauth2‑proxy**; if `OAUTH2_PROXY_REDIS_ENABLED=true` it also installs **Redis** for session storage.
* Starts short‑lived **port‑forwards** to **Hydra admin (4445)** and **Vault (8200)**.
* Onboards Kubernetes auth in Vault + ESO `role` **only if `VAULT_TOKEN` is defined**.
* Registers **Hydra OAuth clients** from `deploy/ory/clients.yaml` (idempotent PUT/POST).

> If Vault onboarding is skipped (no token), set `VAULT_TOKEN` and **re‑run** `just sso-bootstrap`.

### 5) Core services & Observability & UX

```bash
just deploy-core     # RabbitMQ, n8n, Flagsmith
just deploy-obs      # OTel Collector, Loki, Tempo, Grafana
just deploy-ux       # Homepage, Guacamole, Vaultwarden, MCP Context Forge
```

* All `helm upgrade --install` or `kubectl apply` and safe to re‑run.

### 6) Generate and run a sample app (Nx)

```bash
pnpm nx g @org/nx-homelab-plugin:service my-api
# This creates apps/my-api with FastAPI + k8s manifests (+ ExternalSecret)
# Build/publish container and apply manifests as needed (CI step TBD).
```

### 7) Basic validation / doctor

```bash
just doctor
# Writes JSON + Markdown reports to tools/audit/reports/
```

---

## Project layout & where to make changes

```
.
├── README.md
├── Justfile                     # canonical ops entrypoints (HELM+kubectl)
├── package.json / nx.json / tsconfig.base.json
├── tools/
│   ├── plugins/@org/nx-homelab-plugin/…   # Nx generator: FastAPI service + k8s + ExternalSecret
│   ├── scripts/
│   │   ├── configure_network.py           # Detect host IP + patch MetalLB pool
│   │   ├── hydra_clients.py               # Idempotent Hydra client registrar
│   │   ├── vault_init.sh                  # One-click Vault initialize/unseal/token
│   │   └── vault_k8s_onboard.sh           # Configure Vault K8s auth + ESO role
│   └── audit/
│       ├── audit_readiness.py             # Full readiness report (CLI, k8s, ports)
│       ├── audit_wsl.sh                   # Quick WSL2 audit
│       └── audit_windows.ps1              # Windows host audit
└── deploy/
    ├── metallb/ipaddresspool.yaml         # Patched by configure-network
    ├── eso/vault-clustersecretstore.yaml  # ESO -> Vault KV v2 config (k8s auth “eso” role)
    ├── vault/values.yaml                  # Vault Helm values (Raft, ui, no TLS)
    ├── argocd/{values.yaml,app-of-apps.yaml}
    ├── ory/{kratos-values.yaml,hydra-values.yaml,clients.yaml}
    ├── oauth2-proxy/values.yaml
    ├── redis/values.yaml
    ├── rabbitmq/values.yaml
    ├── n8n/values.yaml
    ├── flagsmith/deploy.yaml
    ├── observability/{otel-values.yaml,loki-values.yaml,tempo-values.yaml,mimir-values.yaml,grafana-values.yaml}
    └── {guacamole, vaultwarden, mcp}/…    # UX apps
```

**Key config hotspots for agents:**

* **Domain** default is `homelab.lan`. Change via `export DOMAIN=…` before `just sso-bootstrap`.
  `deploy/ory/clients.yaml` redirect URIs are **auto‑rewritten** to the `DOMAIN` at registration time.
* **MetalLB pool** is **auto‑patched**. **Do not hardcode** IPs in services—use Ingress for most apps.
* **Vault/ESO binding**: ESO uses `ClusterSecretStore` named `vault-kv` and Vault role **`eso`** (created by `vault_k8s_onboard.sh`). If you add namespaces or service accounts, update that script and the CR accordingly.
* **CNI**: `install-foundation` installs Cilium unless `SKIP_CILIUM=true`. Leave this flag on if cluster currently uses flannel and you’re avoiding a CNI cutover.

---

## CI / validation expectations

* There is **no GitHub Actions workflow** in this scaffold yet. Agents should validate locally using:

  * `just doctor` (environment and cluster checks).
  * Idempotent deploys: `just install-foundation`, `just sso-bootstrap`, `just deploy-*`.
  * For app changes, ensure manifests apply and services respond (e.g., port‑forward to a service and hit `/`).

**Pre‑commit hygiene (recommended for agents):**

* Keep changes **idempotent** (no imperative, stateful scripts that assume a prior step succeeded silently).
* Avoid committing secrets; prefer **Vault KV v2** + **ExternalSecret** references.
* For new services, **always**:

  1. Add k8s `Deployment`, `Service`, `Ingress`.
  2. Add an `ExternalSecret` referencing a path under `kv/apps/<service>/…`.
  3. Ensure OTEL endpoint env is set (`OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318`).

---

## Known pitfalls & workarounds (read before running)

* **WSL2** without **systemd** can cause Helm hooks and services to misbehave. Enable systemd and restart WSL.
* If `just sso-bootstrap` prints `VAULT_TOKEN not set; skipping Vault onboarding`, **export** `VAULT_TOKEN` (or `source tools/secrets/.env.vault`) and **re‑run** `just sso-bootstrap`.
* If Hydra client registration fails with YAML import error, run:

  ```bash
  python3 -m pip install pyyaml
  ```
* If the cluster already binds ports 80/443 on the **host**, avoid hostPort or host‑bound services; this scaffold uses **Ingress** via Traefik and **ClusterIP** services by default.

---

## What the agent should do (and not do)

* **Do:**

  * Use `just` targets exactly as ordered above.
  * Modify **values files** and **manifests** in `deploy/` rather than inlining kubectl commands.
  * Generate new services with the **Nx generator** instead of hand‑crafting boilerplate.
  * Keep all changes **re‑entrant** (safe to re‑run).

* **Do not:**

  * Hardcode IP addresses; rely on Ingress + DNS and the `configure-network` step.
  * Commit secrets. Use Vault KV v2 paths and `ExternalSecret`.
  * Replace `helm upgrade --install` with ad‑hoc `kubectl` unless justified.

---

## Quick reference (commands)

```bash
pnpm install                              # bootstrap
just configure-network                    # auto-pick MetalLB pool for current LAN
export SKIP_CILIUM=true                   # if deferring Cilium install (flannel in use)
just install-foundation                   # namespaces, CRDs, ESO, Vault, Argo CD, (Cilium*)
just vault-init                           # init/unseal/token; optional env file write
just sso-bootstrap                        # Ory, oauth2-proxy(+Redis), Vault onboarding, Hydra clients
just deploy-core && just deploy-obs && just deploy-ux
pnpm nx g @org/nx-homelab-plugin:service my-api
just doctor                               # readiness reports in tools/audit/reports/
```

> **Final instruction to the agent:** Follow these instructions as the source of truth. **Only search the repo** if a step here is missing for your task or fails in practice.
