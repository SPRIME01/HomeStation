# Homelab Readiness Report
Generated: 2025-08-21T00:38:43.661017+00:00

**Summary:** ✅ 48  ⚠️ 1  ❌ 16  ⏭️ 0

## OS & Platform
| Check | Status | Message | Fix Hint |
|---|---|---|---|
| `OS` | ✅ PASS | Linux-6.6.87.2-microsoft-standard-WSL2-x86_64-with-glibc2.39 (WSL2=True) |  |
| `systemd` | ✅ PASS | systemd active |  |
| `virtualization` | ✅ PASS | VMX/SVM present | Enable virtualization in BIOS/UEFI |
| `k3s-install` | ❌ FAIL | k3s dirs missing | Install k3s via rancher installer or verify permissions |

## CLI Tooling
| Check | Status | Message | Fix Hint |
|---|---|---|---|
| `kubectl` | ✅ PASS | clientVersion: |  |
| `helm` | ✅ PASS | v3.18.3+g6838ebc |  |
| `k3s` | ❌ FAIL | not installed | Install k3s and ensure it is on PATH |
| `docker` | ✅ PASS | Docker version 28.1.1-rd, build 4d7f01e |  |
| `nerdctl` | ✅ PASS | wsl: Failed to translate '\\wsl.localhost\Ubuntu\home\prime\homestation' |  |
| `ctr` | ❌ FAIL | not installed | Install ctr and ensure it is on PATH |
| `pulumi` | ✅ PASS | v3.187.0 |  |
| `ansible` | ✅ PASS | ansible [core 2.16.3] |  |
| `argocd` | ❌ FAIL | not installed | Install argocd and ensure it is on PATH |
| `vault` | ❌ FAIL | not installed | Install vault and ensure it is on PATH |
| `sops` | ❌ FAIL | not installed | Install sops and ensure it is on PATH |
| `age` | ❌ FAIL | not installed | Install age and ensure it is on PATH |
| `cosign` | ❌ FAIL | not installed | Install cosign and ensure it is on PATH |
| `syft` | ❌ FAIL | not installed | Install syft and ensure it is on PATH |
| `trivy` | ❌ FAIL | not installed | Install trivy and ensure it is on PATH |
| `git` | ✅ PASS | git version 2.43.0 |  |
| `node` | ✅ PASS | v22.18.0 |  |
| `pnpm` | ✅ PASS | WARN  The "workspaces" field in package.json is not supported by pnpm. Create a "pnpm-workspace.yaml" file instead. |  |
| `python3` | ✅ PASS | Python 3.12.3 |  |
| `uv` | ✅ PASS | uv 0.8.12 |  |
| `rdctl` | ✅ PASS | rdctl client version: v1.19.3, targeting server version: v1 |  |
| `redis-cli` | ❌ FAIL | not installed | Install redis-cli and ensure it is on PATH |

## Kubernetes
| Check | Status | Message | Fix Hint |
|---|---|---|---|
| `cluster` | ✅ PASS | cluster reachable | Ensure kubeconfig / KUBECONFIG and k3s/rancher are running |
| `node-sample` | ✅ PASS | homestation   Ready    control-plane,master   22d   v1.33.3+k3s1   192.168.127.2   <none>        Rancher Desktop WSL Distribution   6.6.87.2-microsoft-standard-WSL2   containerd://2.0.0 |  |
| `cni` | ✅ PASS | unknown |  |
| `traefik` | ✅ PASS | Traefik service detected |  |
| `metallb` | ✅ PASS | metallb-system namespace present | Install MetalLB and configure IPAddressPool + L2Advertisement |
| `argocd` | ✅ PASS | argocd namespace present | Install Argo CD (GitOps) |
| `external-secrets` | ❌ FAIL | ESO not detected | Install External Secrets Operator and configure Vault ClusterSecretStore |
| `vault` | ✅ PASS | vault namespace present | Deploy Vault with Raft + TLS; enable k8s auth |
| `ory` | ❌ FAIL | not installed | Deploy Kratos + Hydra and consent UI |
| `supabase` | ✅ PASS | namespace present | Deploy Supabase; expose only Kong (8000/8443) |
| `rabbitmq` | ❌ FAIL | not installed | Deploy RabbitMQ; mgmt internal; metrics 15692 |
| `observability` | ❌ FAIL | not detected | Deploy docker-otel-lgtm (Grafana/Tempo/Loki/Mimir) |
| `rancher` | ❌ FAIL | not detected | Deploy Rancher (cattle-system) if centralized mgmt desired |
| `rdctl` | ✅ PASS | rdctl client version: v1.19.3, targeting server version: v1 |  |

## Host Ports
| Check | Status | Message | Fix Hint |
|---|---|---|---|
| `port:80` | ✅ PASS | no host bind detected |  |
| `port:443` | ✅ PASS | no host bind detected |  |
| `port:3000` | ✅ PASS | no host bind detected |  |
| `port:4000` | ✅ PASS | no host bind detected |  |
| `port:4317` | ✅ PASS | no host bind detected |  |
| `port:4318` | ✅ PASS | no host bind detected |  |
| `port:4433` | ✅ PASS | no host bind detected |  |
| `port:4434` | ✅ PASS | no host bind detected |  |
| `port:4444` | ✅ PASS | no host bind detected |  |
| `port:4445` | ✅ PASS | no host bind detected |  |
| `port:4822` | ✅ PASS | no host bind detected |  |
| `port:5000` | ✅ PASS | no host bind detected |  |
| `port:5672` | ✅ PASS | no host bind detected |  |
| `port:5678` | ✅ PASS | no host bind detected |  |
| `port:6443` | ✅ PASS | no host bind detected |  |
| `port:8000` | ✅ PASS | no host bind detected |  |
| `port:8080` | ⚠️ WARN | Listening on host: ArgoCD local pf / Guacamole alt web | If this should be cluster-only, remove host binds and expose via Traefik |
| `port:8200` | ✅ PASS | no host bind detected |  |
| `port:8201` | ✅ PASS | no host bind detected |  |
| `port:8443` | ✅ PASS | no host bind detected |  |
| `port:9345` | ✅ PASS | no host bind detected |  |
| `port:9999` | ✅ PASS | no host bind detected |  |
| `port:15672` | ✅ PASS | no host bind detected |  |
| `port:15692` | ✅ PASS | no host bind detected |  |
| `port:19999` | ✅ PASS | no host bind detected |  |
