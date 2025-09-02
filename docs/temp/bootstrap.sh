perfect—here’s a one-shot **`bootstrap.sh`** that reconstructs the entire scaffold (same contents as the zip), sets executable bits, and prints the next commands. It’s **idempotent**: re-running overwrites files safely.

### How to use

```bash
# run this in an empty working dir (or one where you want the repo folder created)
bash bootstrap.sh
# then follow the printed “next steps”
```

---

````bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="homelab-scaffold"

# ---- preflight --------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Please install it and re-run." >&2; exit 1; }; }
need python3

mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

# ---- write all files via an embedded Python builder -------------------------
python3 - <<'PY'
import os, textwrap, pathlib

root = pathlib.Path(".")
def write(rel: str, content: str):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(textwrap.dedent(content).lstrip())

# README
write("README.md", """
# Homelab Scaffold (Nx + Just, SSO + Redis, Vault + ESO, ArgoCD)

Idempotent scaffold using Helm + kubectl apply. Cluster-first (Traefik + DNS + MetalLB).

## Quickstart

### Network auto-config
Run this first to detect your host IP and safely pick a MetalLB pool in your LAN:
```bash
just configure-network
````

1. `just doctor`
2. Optionally set `export SKIP_CILIUM=true` (keep flannel for now; migrate later)
3. `just install-foundation`
4. `just vault-init` (one-click init/unseal + VAULT\_TOKEN helper)
5. `just sso-bootstrap`
6. `just deploy-core && just deploy-obs && just deploy-ux`
7. `pnpm i && pnpm nx g @org/nx-homelab-plugin:service my-api`

> If `hydra_clients.py` reads YAML, install: `python3 -m pip install pyyaml`.

### CNI choice

By default we install **Cilium**. If your current k3s uses flannel and you want to defer a rebuild, set:

```bash
export SKIP_CILIUM=true
```

before running `just install-foundation`.

### Vault one-click helper

Initialize/unseal Vault and set a session token (optionally write `tools/secrets/.envrc.vault`):

```bash
just vault-init
# then:
just sso-bootstrap
```

""")

# package.json / nx / tsconfig / postinstall

write("package.json", """
{
"name": "homelab-scaffold",
"private": true,
"version": "0.1.0",
"packageManager": "pnpm\@9",
"scripts": { "nx": "nx", "postinstall": "node tools/postinstall.js" },
"devDependencies": {
"nx": "^19.8.0",
"typescript": "^5.4.0",
"@nx/js": "^19.8.0",
"@nx/workspace": "^19.8.0",
"ts-node": "^10.9.2"
},
"workspaces": \["tools/plugins/\*"]
}
""")
write("nx.json", """
{
"extends": "nx/presets/npm.json",
"npmScope": "org",
"affected": { "defaultBase": "main" },
"tasksRunnerOptions": { "default": { "runner": "nx/tasks-runners/default" } },
"workspaceLayout": { "appsDir": "apps", "libsDir": "libs" }
}
""")
write("tsconfig.base.json", """
{
"compilerOptions": {
"target": "ES2022",
"module": "commonjs",
"moduleResolution": "node",
"resolveJsonModule": true,
"esModuleInterop": true,
"forceConsistentCasingInFileNames": true,
"skipLibCheck": true,
"strict": true,
"types": \["node"]
}
}
""")
write("tools/postinstall.js", "console.log('postinstall complete');\n")

# Justfile (idempotent targets)

write("Justfile", r"""
set shell := \["bash", "-cu"]

export DOMAIN ?= homelab.lan
export METALLB\_POOL\_CIDR ?= 192.168.1.240-192.168.1.250
export NAMESPACE\_SSO ?= sso
export NAMESPACE\_OBS ?= observability
export NAMESPACE\_CORE ?= core
export NAMESPACE\_INFRA ?= infra
export HYDRA\_ADMIN\_URL ?= [http://hydra-admin.\$(NAMESPACE\_SSO).svc.cluster.local:4445](http://hydra-admin.$%28NAMESPACE_SSO%29.svc.cluster.local:4445)
export KRATOS\_PUBLIC\_URL ?= [http://kratos-public.\$(NAMESPACE\_SSO).svc.cluster.local:4433](http://kratos-public.$%28NAMESPACE_SSO%29.svc.cluster.local:4433)
export OAUTH2\_PROXY\_REDIS\_ENABLED ?= true

helm-repos:
helm repo add cilium [https://helm.cilium.io](https://helm.cilium.io) || true
helm repo add metallb [https://metallb.github.io/metallb](https://metallb.github.io/metallb) || true
helm repo add hashicorp [https://helm.releases.hashicorp.com](https://helm.releases.hashicorp.com) || true
helm repo add argo [https://argoproj.github.io/argo-helm](https://argoproj.github.io/argo-helm) || true
helm repo add grafana [https://grafana.github.io/helm-charts](https://grafana.github.io/helm-charts) || true
helm repo add bitnami [https://charts.bitnami.com/bitnami](https://charts.bitnami.com/bitnami) || true
helm repo add external-secrets [https://charts.external-secrets.io](https://charts.external-secrets.io) || true
helm repo add ory [https://k8s.ory.sh/helm/charts](https://k8s.ory.sh/helm/charts) || true
helm repo add oauth2-proxy [https://oauth2-proxy.github.io/manifests](https://oauth2-proxy.github.io/manifests) || true
helm repo add open-telemetry [https://open-telemetry.github.io/opentelemetry-helm-charts](https://open-telemetry.github.io/opentelemetry-helm-charts) || true
helm repo update

install-foundation: helm-repos
kubectl get ns \$(NAMESPACE\_INFRA) >/dev/null 2>&1 || kubectl create ns \$(NAMESPACE\_INFRA)
kubectl get ns \$(NAMESPACE\_SSO) >/dev/null 2>&1 || kubectl create ns \$(NAMESPACE\_SSO)
kubectl get ns \$(NAMESPACE\_CORE) >/dev/null 2>&1 || kubectl create ns \$(NAMESPACE\_CORE)
kubectl get ns \$(NAMESPACE\_OBS) >/dev/null 2>&1 || kubectl create ns \$(NAMESPACE\_OBS)

```
if [ "${SKIP_CILIUM:-false}" != "true" ]; then \
  echo "Installing Cilium (set SKIP_CILIUM=true to skip)"; \
  helm upgrade --install cilium cilium/cilium -n kube-system --set kubeProxyReplacement=strict || true; \
else \
  echo "Skipping Cilium install (SKIP_CILIUM=true)"; \
fi

helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
kubectl apply -f deploy/metallb/ipaddresspool.yaml

helm upgrade --install external-secrets external-secrets/external-secrets -n $(NAMESPACE_INFRA) --set installCRDs=true
kubectl apply -f deploy/eso/vault-clustersecretstore.yaml

helm upgrade --install vault hashicorp/vault -n $(NAMESPACE_INFRA) -f deploy/vault/values.yaml

helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f deploy/argocd/values.yaml
```

sso-bootstrap: helm-repos
\# Auto-detect LAN and adjust MetalLB pool (safe re-run)
python3 tools/scripts/configure\_network.py --write || true

```
helm upgrade --install kratos ory/kratos -n $(NAMESPACE_SSO) -f deploy/ory/kratos-values.yaml
helm upgrade --install hydra ory/hydra -n $(NAMESPACE_SSO) -f deploy/ory/hydra-values.yaml
```

if \[ "\$(OAUTH2\_PROXY\_REDIS\_ENABLED)" = "true" ]; then&#x20;
helm upgrade --install redis bitnami/redis -n \$(NAMESPACE\_SSO) -f deploy/redis/values.yaml;&#x20;
fi
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy -n \$(NAMESPACE\_SSO) -f deploy/oauth2-proxy/values.yaml

```
# Start short-lived port-forwards (Hydra admin 4445, Vault 8200)
set -e
PF_HYDRA=""; PF_VAULT="";
trap '[[ -n "$PF_HYDRA" ]] && kill $PF_HYDRA 2>/dev/null || true; [[ -n "$PF_VAULT" ]] && kill $PF_VAULT 2>/dev/null || true' EXIT
(kubectl -n $(NAMESPACE_SSO) port-forward svc/hydra-admin 4445:4445 >/tmp/pf_hydra.log 2>&1 & echo $! > /tmp/pf_hydra.pid)
sleep 2
PF_HYDRA=$(cat /tmp/pf_hydra.pid || true)
(kubectl -n $(NAMESPACE_INFRA) port-forward svc/vault 8200:8200 >/tmp/pf_vault.log 2>&1 & echo $! > /tmp/pf_vault.pid) || true
sleep 2
PF_VAULT=$(cat /tmp/pf_vault.pid || true)

# Use localhost endpoints for admin APIs
export HYDRA_ADMIN_URL="http://127.0.0.1:4445"
export VAULT_ADDR="http://127.0.0.1:8200"

# Vault onboarding (requires VAULT_TOKEN). Skip if not present.
if [ -n "${VAULT_TOKEN:-}" ]; then \
  echo "Running Vault onboarding with VAULT_TOKEN (k8s auth + ESO role)"; \
  bash tools/scripts/vault_k8s_onboard.sh || true; \
else \
  echo "VAULT_TOKEN not set; skipping Vault onboarding. Set VAULT_TOKEN and re-run sso-bootstrap to enable."; \
fi

# Register Hydra clients idempotently
python3 tools/scripts/hydra_clients.py --admin "$HYDRA_ADMIN_URL" --domain $(DOMAIN) --config deploy/ory/clients.yaml
```

deploy-core: helm-repos
helm upgrade --install rabbitmq bitnami/rabbitmq -n \$(NAMESPACE\_CORE) -f deploy/rabbitmq/values.yaml
helm upgrade --install n8n bitnami/n8n -n \$(NAMESPACE\_CORE) -f deploy/n8n/values.yaml || true
kubectl apply -n \$(NAMESPACE\_CORE) -f deploy/flagsmith/deploy.yaml

deploy-obs: helm-repos
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n \$(NAMESPACE\_OBS) -f deploy/observability/otel-values.yaml
helm upgrade --install loki grafana/loki -n \$(NAMESPACE\_OBS) -f deploy/observability/loki-values.yaml
helm upgrade --install tempo grafana/tempo -n \$(NAMESPACE\_OBS) -f deploy/observability/tempo-values.yaml
helm upgrade --install mimir grafana/mimir-distributed -n \$(NAMESPACE\_OBS) -f deploy/observability/mimir-values.yaml || true
helm upgrade --install grafana grafana/grafana -n \$(NAMESPACE\_OBS) -f deploy/observability/grafana-values.yaml

deploy-ux:
helm upgrade --install homepage --namespace \$(NAMESPACE\_CORE) --create-namespace oci://ghcr.io/gethomepage/homepage --version 0.9.11 || true
kubectl apply -n \$(NAMESPACE\_CORE) -f deploy/guacamole/guacd.yaml
kubectl apply -n \$(NAMESPACE\_CORE) -f deploy/guacamole/guacamole.yaml
kubectl apply -n \$(NAMESPACE\_CORE) -f deploy/vaultwarden/deploy.yaml
kubectl apply -n \$(NAMESPACE\_CORE) -f deploy/mcp/contextforge.yaml

gitops:
kubectl apply -n argocd -f deploy/argocd/app-of-apps.yaml || true

generate service=:
pnpm nx g @org/nx-homelab-plugin\:service {{service}}

audit:
@mkdir -p tools/audit/reports
@python3 tools/audit/audit\_readiness.py --format both --out tools/audit/reports

audit-quick:
@bash tools/audit/audit\_wsl.sh

audit-windows:
@pwsh -NoProfile -ExecutionPolicy Bypass -File tools/audit/audit\_windows.ps1

doctor: audit-quick audit
@echo "Doctor completed. See tools/audit/reports/readiness.md"

# Detect host IP/CIDR and write MetalLB pool safely

configure-network:
python3 tools/scripts/configure\_network.py --write

# Initialize and/or unseal Vault with safe prompts and optional env file

vault-init:
bash tools/scripts/vault\_init.sh
""")

# Scripts

write("tools/scripts/hydra\_clients.py", """
\#!/usr/bin/env python3
import argparse, json, sys, urllib.request
def http(method, url, data=None):
req = urllib.request.Request(url, method=method, headers={'Content-Type':'application/json'})
if data is not None:
req.data = json.dumps(data).encode()
with urllib.request.urlopen(req) as r:
return json.loads(r.read().decode())
def main():
ap = argparse.ArgumentParser()
ap.add\_argument('--admin', required=True)
ap.add\_argument('--domain', required=True)
ap.add\_argument('--config', required=True)
args = ap.parse\_args()
if args.config.endswith(('.yaml','.yml')):
try:
import yaml
except ImportError:
print("Install pyyaml or convert to JSON.", file=sys.stderr); sys.exit(1)
cfg = yaml.safe\_load(open(args.config))
else:
cfg = json.load(open(args.config))
existing = {c\["client\_id"]: c for c in http("GET", args.admin + "/clients")}
for c in cfg.get("clients", \[]):
c\["redirect\_uris"] = \[u.replace("homelab.lan", args.domain) for u in c.get("redirect\_uris", \[])]
cid = c\["client\_id"]
if cid in existing:
http("PUT", f"{args.admin}/clients/{cid}", c); print("Updated client:", cid)
else:
http("POST", f"{args.admin}/clients", c); print("Created client:", cid)
if **name** == "**main**":
main()
""")

write("tools/scripts/vault\_k8s\_onboard.sh", r"""
\#!/usr/bin/env bash
set -euo pipefail

# Requires: VAULT\_ADDR=[http://127.0.0.1:8200](http://127.0.0.1:8200) and VAULT\_TOKEN set (port-forward is started by sso-bootstrap).

if ! vault auth list 2>/dev/null | grep -q kubernetes; then
vault auth enable kubernetes || true
fi

SA\_NAME=\$(kubectl -n infra get sa vault -o jsonpath='{.secrets\[0].name}' 2>/dev/null || echo "")
if \[ -z "\$SA\_NAME" ]; then
echo "Vault ServiceAccount secret not found in 'infra' namespace. Ensure Vault chart deployed."
exit 0
fi

SA\_TOKEN=\$(kubectl -n infra get secret "\$SA\_NAME" -o jsonpath='{.data.token}' | base64 -d)
KUBE\_HOST=\$(kubectl config view --minify -o jsonpath='{.clusters\[0].cluster.server}')
KUBE\_CA=\$(kubectl -n infra get secret "\$SA\_NAME" -o jsonpath='{.data.ca.crt}' | base64 -d)

vault write auth/kubernetes/config token\_reviewer\_jwt="\$SA\_TOKEN" kubernetes\_host="\$KUBE\_HOST" kubernetes\_ca\_cert="\$KUBE\_CA" >/dev/null || true

vault policy write eso-reader - <\<EOF
path "kv/data/apps/\*" {
capabilities = \["read"]
}
EOF

vault write auth/kubernetes/role/eso&#x20;
bound\_service\_account\_names=default&#x20;
bound\_service\_account\_namespaces="core,infra,observability,sso"&#x20;
policies=eso-reader&#x20;
ttl=24h >/dev/null || true

echo "Vault k8s auth & ESO role configured."
""")

write("tools/scripts/configure\_network.py", r"""
\#!/usr/bin/env python3
import argparse, ipaddress, subprocess, re, sys

def sh(cmd):
return subprocess.check\_output(cmd, shell=True, text=True).strip()

def detect\_default\_ipv4():
out = sh("ip -4 route show default || true")
m = re.search(r"default via (\d+.\d+.\d+.\d+) dev (\S+)(?:.\*?src (\d+.\d+.\d+.\d+))?", out)
if m:
gw, dev, src = m.group(1), m.group(2), m.group(3) or ""
if not src:
addrs = sh(f"ip -4 -o addr show dev {dev} | awk '{{print \$4}}' | cut -d/ -f1 || true").splitlines()
src = addrs\[0] if addrs else ""
return {"gw"\:gw, "dev"\:dev, "ip"\:src}
return {"gw":"", "dev":"", "ip":""}

def choose\_pool(cidr, host\_ip):
net = ipaddress.ip\_network(cidr, strict=False)
hosts = list(net.hosts())
if net.prefixlen == 24 and len(hosts) >= 250:
start = ipaddress.ip\_address(int(net.network\_address) + 240)
end   = ipaddress.ip\_address(int(net.network\_address) + 250)
else:
start = hosts\[-11]; end = hosts\[-1]
hip = ipaddress.ip\_address(host\_ip)
if start <= hip <= end:
start = ipaddress.ip\_address(int(start) - 16)
end   = ipaddress.ip\_address(int(end) - 16)
return f"{start}-{end}"

def patch\_metallb\_pool(file\_path, pool):
import re, pathlib
p = pathlib.Path(file\_path)
txt = p.read\_text()
new = re.sub(r"addresses:\s\*\n\s\*-\s\*\[0-9.-]+", f"addresses:\n    - {pool}", txt)
p.write\_text(new)

def main():
ap = argparse.ArgumentParser()
ap.add\_argument("--pool-start", default="")
ap.add\_argument("--pool-end", default="")
ap.add\_argument("--cidr", default="")
ap.add\_argument("--file", default="deploy/metallb/ipaddresspool.yaml")
ap.add\_argument("--write", action="store\_true")
args = ap.parse\_args()

```
det = detect_default_ipv4()
if not det["ip"]:
    print("Could not detect default IPv4; specify --cidr and --pool-* manually.", file=sys.stderr)
    sys.exit(1)

host_ip = det["ip"]
cidr = args.cidr or ".".join(host_ip.split(".")[:3]) + ".0/24"
pool = (args.pool_start and args.pool_end) and f"{args.pool_start}-{args.pool_end}" or choose_pool(cidr, host_ip)
print(f"Detected host IP: {host_ip}, CIDR: {cidr}, MetalLB pool: {pool}")
if args.write:
    patch_metallb_pool(args.file, pool)
    print(f"Updated {args.file}")
```

if **name** == "**main**":
main()
""")

write("tools/scripts/vault\_init.sh", r"""
\#!/usr/bin/env bash
set -euo pipefail

NS="\${NAMESPACE\_INFRA:-infra}"
SVC="\${VAULT\_SERVICE\_NAME:-vault}"
ENV\_FILE="tools/secrets/.envrc.vault"

if ! command -v vault >/dev/null 2>&1; then
echo "ERROR: vault CLI not found. Install HashiCorp Vault CLI and try again."
exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
echo "ERROR: kubectl not found."
exit 1
fi

mkdir -p tools/secrets

echo "== Vault init helper =="
echo "Namespace: \$NS  Service: \$SVC"
echo "Starting short-lived port-forward to \$NS/\$SVC on 127.0.0.1:8200..."

PF\_VAULT=""
trap '\[\[ -n "\$PF\_VAULT" ]] && kill \$PF\_VAULT 2>/dev/null || true' EXIT
(kubectl -n "\$NS" port-forward "svc/\$SVC" 8200:8200 >/tmp/pf\_vault\_init.log 2>&1 & echo \$! > /tmp/pf\_vault\_init.pid) || true
sleep 2
PF\_VAULT=\$(cat /tmp/pf\_vault\_init.pid || true)

export VAULT\_ADDR="\${VAULT\_ADDR:-[http://127.0.0.1:8200}](http://127.0.0.1:8200})"

echo "Checking Vault status at \$VAULT\_ADDR ..."
STATUS\_JSON=""
if vault status -format=json >/tmp/vault\_status.json 2>/dev/null; then
STATUS\_JSON=\$(cat /tmp/vault\_status.json)
fi

initialized="unknown"
sealed="unknown"

if \[\[ -n "\$STATUS\_JSON" ]]; then
initialized=\$(grep -o '"initialized":\[^,]*' /tmp/vault\_status.json | awk -F: '{print \$2}' | tr -d ' ')
sealed=\$(grep -o '"sealed":\[^,]*' /tmp/vault\_status.json | awk -F: '{print \$2}' | tr -d ' ')
else
OUT=\$(vault status || true)
if echo "\$OUT" | grep -qi "Initialized.\*true"; then initialized="true"; else initialized="false"; fi
if echo "\$OUT" | grep -qi "Sealed.\*true"; then sealed="true"; else sealed="false"; fi
fi

echo "initialized=\$initialized  sealed=\$sealed"

write\_env\_file() {
local token="\$1"
read -r -p "Write VAULT\_TOKEN to \$ENV\_FILE (chmod 600)? \[y/N] " ans || true
if \[\[ "\${ans:-}" =\~ ^\[Yy]\$ ]]; then
umask 177
mkdir -p "\$(dirname "\$ENV\_FILE")"
printf 'export VAULT\_ADDR=%q\nexport VAULT\_TOKEN=%q\n' "\$VAULT\_ADDR" "\$token" > "\$ENV\_FILE"
chmod 600 "\$ENV\_FILE"
echo "Wrote \$ENV\_FILE (permissions 600). You can: source \$ENV\_FILE"
else
echo "Not writing env file. Remember to: export VAULT\_TOKEN=<token>"
fi
}

if \[\[ "\$initialized" == "false" ]]; then
echo "Vault is not initialized."
read -r -p "Initialize Vault now with 1 unseal key and 1 threshold? \[y/N] " ans || true
if \[\[ ! "\${ans:-}" =\~ ^\[Yy]\$ ]]; then
echo "Aborting init per user choice."
exit 0
fi

echo "Initializing..."
INIT\_OUT=\$(vault operator init -key-shares=1 -key-threshold=1)
echo "===== IMPORTANT SECRETS (DISPLAY ONLY) ====="
echo "\$INIT\_OUT"
echo "===== END SECRETS ====="
UNSEAL=\$(echo "\$INIT\_OUT" | grep 'Unseal Key 1:' | awk '{print \$4}')
ROOT=\$(echo "\$INIT\_OUT" | grep 'Initial Root Token:' | awk '{print \$4}')
if \[\[ -z "\$UNSEAL" || -z "\$ROOT" ]]; then
echo "Failed to parse unseal or root token. Please re-run and/or copy manually."
exit 1
fi
echo "Unsealing once..."
vault operator unseal "\$UNSEAL" >/dev/null
export VAULT\_TOKEN="\$ROOT"
echo "Exported VAULT\_TOKEN for this process only."
write\_env\_file "\$ROOT"
echo "Initialization complete."
echo "TIP: Store the Unseal Key and Root Token safely in your password manager (Vaultwarden) and delete any copies."
exit 0
fi

if \[\[ "\$sealed" == "true" ]]; then
echo "Vault is initialized but sealed."
read -r -s -p "Enter Unseal Key: " UNSEAL\_KEY
echo
if \[\[ -z "\$UNSEAL\_KEY" ]]; then
echo "No unseal key provided; aborting."
exit 1
fi
vault operator unseal "\$UNSEAL\_KEY" >/dev/null
echo "Unsealed."
fi

HAS\_TOKEN=0
if vault token lookup >/dev/null 2>&1; then
HAS\_TOKEN=1
fi

if \[\[ "\$HAS\_TOKEN" -ne 1 ]]; then
echo "No valid VAULT\_TOKEN in environment."
read -r -s -p "Enter an admin/root token to export for this shell: " TOK
echo
if \[\[ -z "\$TOK" ]]; then
echo "No token provided; continuing without exporting."
else
export VAULT\_TOKEN="\$TOK"
echo "Exported VAULT\_TOKEN for this process."
write\_env\_file "\$TOK"
fi
fi

echo "Vault is ready. You can now run: 'just sso-bootstrap'."
""")

# Audit tools

write("tools/audit/audit\_readiness.py", """
\#!/usr/bin/env python3
import argparse, json, os, platform, shutil, subprocess, sys
from datetime import datetime
from pathlib import Path
def run(cmd, timeout=10, capture=True):
try:
if capture:
out = subprocess.check\_output(cmd, stderr=subprocess.STDOUT, timeout=timeout, text=True)
return 0, out.strip()
else:
p = subprocess.run(cmd, timeout=timeout)
return p.returncode, ""
except Exception as e:
return 1, str(e)
def which(x): return shutil.which(x)
def listen\_ports():
for probe in \[\["ss","-lntp"],\["ss","-lnt"],\["netstat","-ano"],\["lsof","-iTCP","-sTCP\:LISTEN","-n","-P"]]:
if which(probe\[0]):
rc,out = run(probe)
if rc==0: return out
return ""
def is\_wsl():
try:
return "microsoft" in open("/proc/version").read().lower()
except: return False
def kget(args): return run(\["kubectl"]+args, timeout=15)
KNOWN\_CMDS = {
"kubectl":\["kubectl","version","--client","--output=yaml"],
"helm":\["helm","version","--short"],
"pulumi":\["pulumi","version"],
"ansible":\["ansible","--version"],
"argocd":\["argocd","version","--client"],
"vault":\["vault","version"],
"sops":\["sops","--version"],
"age":\["age","--version"],
"cosign":\["cosign","version"],
"syft":\["syft","version"],
"trivy":\["trivy","--version"],
"git":\["git","--version"],
"node":\["node","-v"],
"pnpm":\["pnpm","-v"],
"python3":\["python3","--version"],
"uv":\["uv","--version"],
"redis-cli":\["redis-cli","--version"],
}
KNOWN\_PORTS = {80:"Traefik HTTP",443:"Traefik HTTPS",8080:"ArgoCD/Guac alt",8200:"Vault API",8201:"Vault cluster",3000:"Grafana/etc",15672:"RabbitMQ mgmt",15692:"RabbitMQ metrics",5672:"AMQP",19999:"Netdata",4317:"OTel gRPC",4318:"OTel HTTP",8000:"Kong",8443:"Kong TLS/Guac",4822:"guacd",4444:"Hydra public",4445:"Hydra admin",4433:"Kratos public",4434:"Kratos admin",5678:"n8n"}
def status(pass\_=None, warn=False, msg="", fix=""):
if pass\_ is None and warn: level="WARN"
elif pass\_: level="PASS"
else: level="FAIL"
return {"level"\:level,"message"\:msg,"fix"\:fix}
def check\_os\_env():
items=\[]
items.append(("OS", status(True, msg=f"{platform.platform()} (WSL2={is\_wsl()})")))
if which("systemctl"):
rc,out = run(\["systemctl","is-system-running"], timeout=5)
if rc==0 and "running" in out: items.append(("systemd", status(True, msg="systemd active")))
else: items.append(("systemd", status(None, warn=True, msg=f"systemd not fully running ({out})", fix="Enable systemd in /etc/wsl.conf and restart WSL")))
else:
items.append(("systemd", status(None, warn=True, msg="systemctl not found", fix="Enable systemd in WSL or proceed without it")))
return items
def check\_cmds():
rows=\[]
for name, cmd in KNOWN\_CMDS.items():
if which(cmd\[0]):
rc,out = run(cmd)
rows.append((name, status(rc==0, msg=(out.splitlines()\[0] if out else "ok"))))
else:
rows.append((name, status(False, msg="not installed", fix=f"Install {name} and ensure PATH")))
return rows
def check\_k8s():
rows=\[]
if not which("kubectl"):
rows.append(("kubectl", status(False, msg="kubectl not installed"))); return rows
rc,out = kget(\["cluster-info"]); rows.append(("cluster", status(rc==0, msg="cluster reachable" if rc==0 else out)))
rc,pods = kget(\["-n","kube-system","get","pods","-o","name"])
cni="unknown"
if rc==0:
if "cilium" in pods: cni="cilium"
elif "calico" in pods: cni="calico"
elif "flannel" in pods: cni="flannel"
rows.append(("cni", status(True, msg=cni)))
rc,svc = kget(\["-n","kube-system","get","svc","-o","wide"])
rows.append(("traefik", status(rc==0 and "traefik" in svc, msg="Traefik detected" if rc==0 else "svc query failed")))
rc,\_ = kget(\["get","ns","metallb-system"]); rows.append(("metallb", status(rc==0, msg="present" if rc==0 else "not installed", fix="Install MetalLB")))
rc,\_ = kget(\["get","ns","argocd"]); rows.append(("argocd", status(rc==0, msg="present" if rc==0 else "not installed", fix="Install ArgoCD")))
rc,crd = kget(\["get","crd"]); eso = (rc==0 and "externalsecrets.external-secrets.io" in crd)
rows.append(("external-secrets", status(eso, msg="CRDs found" if eso else "not detected", fix="Install External Secrets Operator")))
rc,\_ = kget(\["get","ns","vault"]); rows.append(("vault", status(rc==0, msg="present" if rc==0 else "not installed", fix="Deploy Vault")))
rc,\_ = kget(\["get","ns","sso"]); rows.append(("ory", status(rc==0, msg="sso ns present" if rc==0 else "not installed", fix="Deploy Kratos + Hydra")))
return rows
def check\_ports():
out = listen\_ports(); rows=\[]
if not out:
rows.append(("ports", status(None, warn=True, msg="could not list listening ports"))); return rows
import re
for p,desc in sorted(KNOWN\_PORTS.items()):
if re.search(rf":{p}\b", out):
rows.append((f"port:{p}", status(None, warn=True, msg=f"Host listening: {desc}", fix="Prefer Ingress + DNS, avoid host binds")))
else:
rows.append((f"port:{p}", status(True, msg="no host bind")))
return rows
def summarize(sections):
summary={"PASS":0,"WARN":0,"FAIL":0}
for \_, items in sections.items():
for \_, st in items:
summary\[st\["level"]]+=1
return summary
def to\_md(sections, summary):
def badge(l): return {"PASS":"✅","WARN":"⚠️","FAIL":"❌"}\[l]
lines=\[f"# Readiness Report\nGenerated: {datetime.utcnow().isoformat()}Z\n", f"**Summary:** ✅ {summary\['PASS']}  ⚠️ {summary\['WARN']}  ❌ {summary\['FAIL']}\n"]
for name, items in sections.items():
lines.append(f"## {name}")
lines.append("| Check | Status | Message | Fix |")
lines.append("|---|---|---|---|")
for check, st in items:
lines.append(f"| `{check}` | {badge(st\['level'])} {st\['level']} | {st\['message']} | {st\['fix']} |")
lines.append("")
return "\n".join(lines)
def main():
ap = argparse.ArgumentParser()
ap.add\_argument("--out", default="tools/audit/reports")
ap.add\_argument("--format", choices=\["json","md","both"], default="both")
ap.add\_argument("--strict", action="store\_true")
args = ap.parse\_args()
sections = {"OS & Platform": check\_os\_env(), "CLI Tooling": check\_cmds(), "Kubernetes": check\_k8s(), "Host Ports": check\_ports()}
summary = summarize(sections)
data = {"generated\_at": datetime.utcnow().isoformat()+"Z", "summary": summary, "sections": {k:\[{"check"\:c, \*\*s} for c,s in v] for k,v in sections.items()}}
outdir = Path(args.out); outdir.mkdir(parents=True, exist\_ok=True)
(outdir/"readiness.json").write\_text(json.dumps(data, indent=2))
(outdir/"readiness.md").write\_text(to\_md(sections, summary))
if args.strict and summary\["FAIL"]>0: sys.exit(2)
if **name** == "**main**":
main()
""")

write("tools/audit/audit\_wsl.sh", """
\#!/usr/bin/env bash
set -euo pipefail
echo "== Quick WSL2 + k8s audit =="
if grep -qi microsoft /proc/version; then echo "WSL: detected"; else echo "WSL: not detected"; fi
if command -v systemctl >/dev/null 2>&1; then
if systemctl is-system-running --quiet 2>/dev/null; then echo "systemd: running"; else echo "systemd: present but not fully running"; fi
else
echo "systemd: not available"
fi
for c in kubectl helm pulumi ansible vault sops age argocd node pnpm uv git; do
if command -v "\$c" >/dev/null 2>&1; then v=\$("\$c" --version 2>/dev/null | head -n1 || echo ok); echo "cli:\$c -> \$v"; else echo "cli:\$c -> MISSING"; fi
done
if command -v kubectl >/dev/null 2>&1; then
kubectl cluster-info || true
kubectl get ns | awk '{print \$1}' | tail -n +2 | tr '\n' ' '; echo
kubectl get svc -A | awk '\$5=="LoadBalancer"{print \$1"/"\$2" -> "\$4}'
fi
kubectl get svc -n kube-system 2>/dev/null | grep -i traefik && echo "Traefik: OK" || echo "Traefik: not found"
kubectl get ns metallb-system >/dev/null 2>&1 && echo "MetalLB: OK" || echo "MetalLB: not found"
kubectl get crd 2>/dev/null | grep -q externalsecrets && echo "External Secrets: OK" || echo "External Secrets: not found"
echo "== Quick audit done =="
""")

write("tools/audit/audit\_windows.ps1", """
\$ErrorActionPreference = "SilentlyContinue"
Write-Host "== Windows Host Audit =="
\$os = Get-ComputerInfo | Select-Object OsName, OsVersion, OsBuildNumber
Write-Host ("OS: {0} {1} (Build {2})" -f \$os.OsName, \$os.OsVersion, \$os.OsBuildNumber)
wsl.exe --version
wsl.exe -l -v
\$vm = Get-CimInstance -ClassName Win32\_Processor | Select-Object -ExpandProperty VirtualizationFirmwareEnabled
Write-Host ("VirtualizationFirmwareEnabled: {0}" -f \$vm)
\$ports = 80,443,8080,8200,8201,3000,15672,15692,5672,19999,4317,4318,8000,8443,4822,4444,4445,4433,4434,5678
Write-Host "\`nListening ports (common set):"
foreach (\$p in \$ports) {
\$inuse = (Get-NetTCPConnection -State Listen -LocalPort \$p -ErrorAction SilentlyContinue)
if (\$inuse) { Write-Host (" - Port {0}: LISTEN" -f \$p) }
}
Write-Host "== Windows audit done =="
""")

# Nx plugin (generator for FastAPI service)

write("tools/plugins/@org/nx-homelab-plugin/package.json", """
{
"name": "@org/nx-homelab-plugin",
"version": "0.1.0",
"main": "src/index.js",
"type": "commonjs",
"generators": "./generators.json",
"dependencies": {}
}
""")
write("tools/plugins/@org/nx-homelab-plugin/generators.json", """
{
"generators": {
"service": {
"factory": "./src/generators/service/generator#serviceGenerator",
"schema": "./src/generators/service/schema.json",
"description": "Generate a FastAPI service with K8s manifests + ExternalSecret"
}
}
}
""")
write("tools/plugins/@org/nx-homelab-plugin/src/index.js", "module.exports = {};\n")
write("tools/plugins/@org/nx-homelab-plugin/src/generators/service/schema.json", """
{
"\$schema": "[http://json-schema.org/schema](http://json-schema.org/schema)",
"title": "Service generator",
"type": "object",
"properties": { "name": { "type": "string" } },
"required": \["name"]
}
""")
write("tools/plugins/@org/nx-homelab-plugin/src/generators/service/generator.ts", """
import \* as fs from 'fs';
import \* as path from 'path';
export interface Schema { name: string; }
export async function serviceGenerator(\_tree: any, schema: Schema) {
const name = schema.name;
const base = path.join('apps', name);
const mkdirp = (p: string) => fs.mkdirSync(p, { recursive: true });
const files: \[string,string]\[] = \[
\['main.py', `from fastapi import FastAPI
app = FastAPI()
@app.get("/")
def hello():
    return {"service":"${name}","status":"ok"}
`],
\['pyproject.toml', `[project]
name = "${name}"
version = "0.1.0"
dependencies = ["fastapi","uvicorn[standard]","opentelemetry-sdk","opentelemetry-instrumentation-fastapi"]
`],
\['Dockerfile', `FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml .
RUN pip install --no-cache-dir fastapi uvicorn[standard] opentelemetry-sdk opentelemetry-instrumentation-fastapi
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8080"]
`],
\['k8s/deployment.yaml', \`apiVersion: apps/v1
kind: Deployment
metadata:
name: \${name}
namespace: core
spec:
replicas: 1
selector: { matchLabels: { app: \${name} } }
template:
metadata: { labels: { app: \${name} } }
spec:
containers:
\- name: \${name}
image: ghcr.io/your/\${name}\:latest
ports: \[{ containerPort: 8080 }]
env:
\- name: OTEL\_EXPORTER\_OTLP\_ENDPOINT
value: [http://otel-collector.observability.svc.cluster.local:4318](http://otel-collector.observability.svc.cluster.local:4318)
envFrom:
\- secretRef: { name: \${name}-secrets }
----------------------------------------

apiVersion: v1
kind: Service
metadata: { name: \${name}, namespace: core }
spec:
selector: { app: \${name} }
ports: \[{ port: 80, targetPort: 8080 }]
----------------------------------------

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: \${name}
namespace: core
annotations: { kubernetes.io/ingress.class: traefik }
spec:
rules:
\- host: \${name}.homelab.lan
http:
paths:
\- path: /
pathType: Prefix
backend: { service: { name: \${name}, port: { number: 80 } } }
tls:
\- hosts: \[\${name}.homelab.lan]
secretName: \${name}-tls
`],     ['k8s/externalsecret.yaml', `apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
name: \${name}-externalsecret
namespace: core
spec:
refreshInterval: 1h
secretStoreRef: { kind: ClusterSecretStore, name: vault-kv }
target: { name: \${name}-secrets }
data:
\- secretKey: APP\_SECRET
remoteRef: { key: kv/apps/\${name}/APP\_SECRET }
`]
  ];
  mkdirp(base);
  for (const [rel, content] of files) {
    const fp = path.join(base, rel); mkdirp(path.dirname(fp));
    fs.writeFileSync(fp, content);
  }
  console.log(`Generated service '\${name}' in \${base}\`);
}
""")

# Deploy manifests

write("deploy/metallb/ipaddresspool.yaml", """
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
name: homelab-pool
namespace: metallb-system
spec:
addresses:
\- 192.168.1.240-192.168.1.250   # <-- Will be auto-adjusted by `just configure-network`
----------------------------------------------------------------------------------------

apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
name: homelab-l2
namespace: metallb-system
spec: {}
""")

write("deploy/vault/values.yaml", """
server:
dataStorage: { enabled: true, size: 5Gi }
ha: { enabled: false }
auditStorage: { enabled: true }
ingress: { enabled: false }
extraEnvironmentVars:
VAULT\_LOCAL\_CONFIG: |
ui = true
listener "tcp" { address = "0.0.0.0:8200" tls\_disable = 1 }
storage "raft" { path = "/vault/data" }
disable\_mlock = true
""")

write("deploy/eso/vault-clustersecretstore.yaml", """
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
name: vault-kv
spec:
provider:
vault:
server: [http://vault.infra.svc.cluster.local:8200](http://vault.infra.svc.cluster.local:8200)
path: kv
version: v2
auth:
kubernetes:
mountPath: kubernetes
role: eso
serviceAccountRef:
name: default
namespace: core
""")

write("deploy/argocd/values.yaml", """
server:
insecure: true
extraArgs: \["--insecure"]
service: { type: ClusterIP }
configs:
cm:
admin.enabled: "true"
""")

write("deploy/argocd/app-of-apps.yaml", """
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: app-of-apps, namespace: argocd }
spec:
project: default
source:
repoURL: [https://github.com/example/your-repo](https://github.com/example/your-repo)
targetRevision: main
path: ops/argo-apps
destination:
server: [https://kubernetes.default.svc](https://kubernetes.default.svc)
namespace: argocd
syncPolicy:
automated: { prune: true, selfHeal: true }
""")

write("deploy/ory/kratos-values.yaml", """
kratos:
config:
serve:
public: { base\_url: [http://kratos-public.svc.cluster.local:4433/](http://kratos-public.svc.cluster.local:4433/) }
identity:
default\_schema\_url: file:///etc/config/identity.schema.json
selfservice:
default\_browser\_return\_url: [https://home.homelab.lan/](https://home.homelab.lan/)
service: { type: ClusterIP }
identitySchemas:
"identity.schema.json": |
{ "\$id":"[https://example/identity.schema.json](https://example/identity.schema.json)", "\$schema":"[http://json-schema.org/draft-07/schema#](http://json-schema.org/draft-07/schema#)",
"title":"User","type":"object",
"properties":{"traits":{"type":"object","properties":{"email":{"type":"string","format":"email"}},"required":\["email"]}} }
""")

write("deploy/ory/hydra-values.yaml", """
hydra:
config:
urls:
self:
issuer: [https://auth.homelab.lan/](https://auth.homelab.lan/)
service:
public: { type: ClusterIP }
admin:  { type: ClusterIP }
""")

write("deploy/ory/clients.yaml", """
clients:

* client\_id: grafana
  client\_name: Grafana
  grant\_types: \["authorization\_code","refresh\_token"]
  response\_types: \["code","id\_token"]
  scope: "openid profile email offline\_access"
  redirect\_uris: \["[https://grafana.homelab.lan/login/generic\_oauth](https://grafana.homelab.lan/login/generic_oauth)"]
* client\_id: argocd
  client\_name: ArgoCD
  grant\_types: \["authorization\_code","refresh\_token"]
  response\_types: \["code"]
  scope: "openid profile email groups offline\_access"
  redirect\_uris: \["[https://argocd.homelab.lan/auth/callback](https://argocd.homelab.lan/auth/callback)"]
* client\_id: vault
  client\_name: Vault OIDC
  grant\_types: \["authorization\_code","refresh\_token"]
  response\_types: \["code"]
  scope: "openid profile email offline\_access"
  redirect\_uris: \["[https://vault.homelab.lan/ui/vault/auth/oidc/oidc/callback](https://vault.homelab.lan/ui/vault/auth/oidc/oidc/callback)"]
* client\_id: oauth2-proxy
  client\_name: oauth2-proxy
  grant\_types: \["authorization\_code","refresh\_token"]
  response\_types: \["code"]
  scope: "openid profile email offline\_access"
  redirect\_uris: \["[https://sso.homelab.lan/oauth2/callback](https://sso.homelab.lan/oauth2/callback)"]
  """)

write("deploy/oauth2-proxy/values.yaml", """
config:
existingSecret: ""
extraArgs:
provider: "oidc"
oidc-issuer-url: "[https://auth.homelab.lan/](https://auth.homelab.lan/)"
cookie-secure: "true"
cookie-samesite: "lax"
email-domain: "\*"
whitelist-domain: ".homelab.lan"
pass-authorization-header: "true"
pass-access-token: "true"
set-xauthrequest: "true"
ssl-insecure-skip-verify: "true"
upstream: "static://200"
redirect-url: "[https://sso.homelab.lan/oauth2/callback](https://sso.homelab.lan/oauth2/callback)"
cookie-refresh: "1h"
cookie-expire: "8h"
redis-connection-url: "redis\://redis-master.sso.svc.cluster.local:6379"
sessionStorage:
type: "redis"
redis:
enabled: false
ingress:
enabled: true
className: traefik
hosts: \[sso.homelab.lan]
path: /
pathType: Prefix
tls: \[{ hosts: \[sso.homelab.lan], secretName: sso-tls }]
""")

write("deploy/redis/values.yaml", """
architecture: standalone
auth: { enabled: false }
master:
persistence: { enabled: true, size: 2Gi }
""")

write("deploy/rabbitmq/values.yaml", """
auth: { username: user, password: rabbitmq }
service: { type: ClusterIP }
metrics:
enabled: true
serviceMonitor: { enabled: false }
""")

write("deploy/n8n/values.yaml", """
service: { type: ClusterIP }
persistence: { enabled: true }
extraEnvVars:

* { name: N8N\_HOST, value: "n8n.homelab.lan" }
* { name: N8N\_PROTOCOL, value: "https" }
  ingress:
  enabled: true
  hostname: n8n.homelab.lan
  ingressClassName: traefik
  tls: true
  """)

write("deploy/flagsmith/deploy.yaml", """
apiVersion: apps/v1
kind: Deployment
metadata: { name: flagsmith, namespace: core }
spec:
replicas: 1
selector: { matchLabels: { app: flagsmith } }
template:
metadata: { labels: { app: flagsmith } }
spec:
containers:
\- name: flagsmith
image: flagsmith/flagsmith\:latest
ports: \[{ containerPort: 8000 }]
---------------------------------

apiVersion: v1
kind: Service
metadata: { name: flagsmith, namespace: core }
spec:
selector: { app: flagsmith }
ports: \[{ port: 8000, targetPort: 8000 }]
------------------------------------------

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: flagsmith
namespace: core
annotations: { kubernetes.io/ingress.class: traefik }
spec:
rules:
\- host: flagsmith.homelab.lan
http:
paths:
\- path: /
pathType: Prefix
backend: { service: { name: flagsmith, port: { number: 8000 } } }
tls: \[{ hosts: \[flagsmith.homelab.lan], secretName: flagsmith-tls }]
""")

write("deploy/observability/otel-values.yaml", """
mode: deployment
config:
receivers:
otlp:
protocols:
http: { endpoint: 0.0.0.0:4318 }
grpc: { endpoint: 0.0.0.0:4317 }
exporters:
otlp:
endpoint: tempo.observability.svc.cluster.local:4317
tls: { insecure: true }
loki:
endpoint: [http://loki.observability.svc.cluster.local:3100/loki/api/v1/push](http://loki.observability.svc.cluster.local:3100/loki/api/v1/push)
processors: { batch: {} }
service:
pipelines:
traces: { receivers: \[otlp], processors: \[batch], exporters: \[otlp] }
logs:   { receivers: \[otlp], processors: \[batch], exporters: \[loki] }
""")

write("deploy/observability/loki-values.yaml", """
loki: { auth\_enabled: false }
singleBinary:
replicas: 1
persistence: { enabled: true, size: 5Gi }
""")

write("deploy/observability/tempo-values.yaml", """
tempo:
storage:
trace:
backend: local
wal: { path: /var/tempo/wal }
local: { path: /var/tempo/traces }
server: { http\_listen\_port: 3200 }
persistence: { enabled: true, size: 5Gi }
""")

write("deploy/observability/mimir-values.yaml", """
global: { project: mimir }
ruler: { enabled: false }
ingester: { replicas: 1 }
distributor: { replicas: 1 }
querier: { replicas: 1 }
store\_gateway: { replicas: 1 }
""")

write("deploy/observability/grafana-values.yaml", """
adminPassword: admin
service: { type: ClusterIP }
ingress:
enabled: true
ingressClassName: traefik
hosts: \[grafana.homelab.lan]
tls: \[{ hosts: \[grafana.homelab.lan], secretName: grafana-tls }]
""")

write("deploy/guacamole/guacd.yaml", """
apiVersion: apps/v1
kind: Deployment
metadata: { name: guacd, namespace: core }
spec:
replicas: 1
selector: { matchLabels: { app: guacd } }
template:
metadata: { labels: { app: guacd } }
spec:
containers:
\- name: guacd
image: guacamole/guacd:1.5.5
ports: \[{ containerPort: 4822 }]
---------------------------------

apiVersion: v1
kind: Service
metadata: { name: guacd, namespace: core }
spec:
selector: { app: guacd }
ports: \[{ port: 4822, targetPort: 4822 }]
""")

write("deploy/guacamole/guacamole.yaml", """
apiVersion: apps/v1
kind: Deployment
metadata: { name: guacamole, namespace: core }
spec:
replicas: 1
selector: { matchLabels: { app: guacamole } }
template:
metadata: { labels: { app: guacamole } }
spec:
containers:
\- name: guacamole
image: guacamole/guacamole:1.5.5
env: \[{ name: GUACD\_HOSTNAME, value: guacd.core.svc.cluster.local }]
ports: \[{ containerPort: 8080 }]
---------------------------------

apiVersion: v1
kind: Service
metadata: { name: guacamole, namespace: core }
spec:
selector: { app: guacamole }
ports: \[{ port: 8080, targetPort: 8080 }]
------------------------------------------

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: guacamole
namespace: core
annotations: { kubernetes.io/ingress.class: traefik }
spec:
rules:
\- host: guac.homelab.lan
http:
paths:
\- path: /
pathType: Prefix
backend: { service: { name: guacamole, port: { number: 8080 } } }
tls: \[{ hosts: \[guac.homelab.lan], secretName: guac-tls }]
""")

write("deploy/vaultwarden/deploy.yaml", """
apiVersion: apps/v1
kind: Deployment
metadata: { name: vaultwarden, namespace: core }
spec:
replicas: 1
selector: { matchLabels: { app: vaultwarden } }
template:
metadata: { labels: { app: vaultwarden } }
spec:
containers:
\- name: vaultwarden
image: vaultwarden/server\:latest
env:
\- { name: WEBSOCKET\_ENABLED, value: "true" }
\- { name: SIGNUPS\_ALLOWED, value: "true" }
\- { name: ADMIN\_TOKEN, valueFrom: { secretKeyRef: { name: vaultwarden-admin, key: token } } }
ports: \[{ containerPort: 80 }]
-------------------------------

apiVersion: v1
kind: Secret
metadata: { name: vaultwarden-admin, namespace: core }
type: Opaque
stringData: { token: "CHANGE\_ME\_ADMIN\_TOKEN" }
-------------------------------------------------

apiVersion: v1
kind: Service
metadata: { name: vaultwarden, namespace: core }
spec:
selector: { app: vaultwarden }
ports: \[{ port: 80, targetPort: 80 }]
--------------------------------------

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: vaultwarden
namespace: core
annotations: { kubernetes.io/ingress.class: traefik }
spec:
rules:
\- host: vaultwarden.homelab.lan
http:
paths:
\- path: /
pathType: Prefix
backend: { service: { name: vaultwarden, port: { number: 80 } } }
tls: \[{ hosts: \[vaultwarden.homelab.lan], secretName: vaultwarden-tls }]
""")

write("deploy/mcp/contextforge.yaml", """
apiVersion: apps/v1
kind: Deployment
metadata: { name: mcp-contextforge, namespace: core }
spec:
replicas: 1
selector: { matchLabels: { app: mcp-contextforge } }
template:
metadata: { labels: { app: mcp-contextforge } }
spec:
containers:
\- name: gateway
image: ghcr.io/ibm/mcp-context-forge\:latest
ports: \[{ containerPort: 8080 }]
---------------------------------

apiVersion: v1
kind: Service
metadata: { name: mcp-contextforge, namespace: core }
spec:
selector: { app: mcp-contextforge }
ports: \[{ port: 80, targetPort: 8080 }]
----------------------------------------

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
name: mcp-contextforge
namespace: core
annotations: { kubernetes.io/ingress.class: traefik }
spec:
rules:
\- host: mcp.homelab.lan
http:
paths:
\- path: /
pathType: Prefix
backend: { service: { name: mcp-contextforge, port: { number: 80 } } }
tls: \[{ hosts: \[mcp.homelab.lan], secretName: mcp-tls }]
""")

PY

# ---- perms & niceties -------------------------------------------------------

chmod +x tools/scripts/vault\_init.sh || true
chmod +x tools/audit/audit\_wsl.sh || true
git init -q >/dev/null 2>&1 || true

cat <<'MSG'

✅ Scaffold reconstructed.

Next steps (copy/paste):

pnpm install
just configure-network
export SKIP\_CILIUM=true           # keep flannel; remove when you’re ready for Cilium
just install-foundation
just vault-init                   # init/unseal/token helper (idempotent)
just sso-bootstrap
just deploy-core
just deploy-obs
just deploy-ux

Optional:

# Generate a new FastAPI service with k8s manifests + ExternalSecret

pnpm nx g @org/nx-homelab-plugin\:service my-api

If you want me to pin a specific MetalLB range or wire DNS hostnames now, say the word and I’ll tweak the generator.
MSG

```
::contentReference[oaicite:0]{index=0}
```
