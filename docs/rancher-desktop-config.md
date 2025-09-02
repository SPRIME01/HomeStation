# Rancher Desktop - HomeStation cluster configuration

This document records the current Rancher Desktop (k3s) cluster choices, the CNI decision (flannel), fixes applied during troubleshooting, and concise commands to reproduce, revert, or retry Cilium later.

> Keep this file under version control. It is a short-lived operational ledger for debugging and future maintenance.

---

## Cluster snapshot

- Cluster distro: k3s (Rancher Desktop WSL VM)
- Kubernetes version: v1.33.3+k3s1
- Node name: `homestation` (single-node)
- CNI: flannel (default for Rancher Desktop)
- Cilium: intentionally removed / not active (default skipped)
- Ingress: Traefik (kube-system)
- Observability: OTel Collector, Loki, Tempo, Grafana (deployed via repo)
- Secrets: External Secrets Operator (ESO) installed
- Load balancer: MetalLB (installed)

---

## Why flannel

- Rancher Desktop defaults to flannel and kubelet expects CNI files under k3s-managed paths.
- Attempting to install Cilium earlier caused kubelet CNI path mismatch and Cilium BPF compile/regeneration failures.
- To stabilize quickly and keep the cluster usable, we reverted to flannel permanently.

---

## Important repo flags / environment

- To keep flannel, no action is required. The installer defaults to skipping Cilium.

- Run foundation installs (uses `SKIP_CILIUM`):

```bash
just install-foundation
```

- If you later want to try Cilium again (fresh attempt):

```bash
# Remove flannel or reset RD, then install Cilium targeted to kubelet
export CILIUM_CNI_BIN_PATH=/usr/libexec/cni
export CILIUM_CNI_CONF_PATH=/etc/cni/net.d
export CILIUM_KUBE_PROXY_REPLACEMENT_DEFAULT=false  # conservative: keep kube-proxy
just install-foundation
```

---

## Steps performed during troubleshooting (chronological)

1. Detected initial failure: kubelet error "failed to find plugin \"cilium-cni\" in path [/usr/libexec/cni]" and Cilium BPF compile errors (macro redefinition).
2. Attempted Option 1 (recommended): update `/etc/rancher/k3s/config.yaml` to set k3s `cni-bin-dir` and `cni-conf-dir` to kubelet-exposed paths, then restart RD. This didn't fully succeed due to residual flannel configs and stale Cilium state.
3. Created symlink fallback: `/usr/libexec/cni/cilium-cni -> /var/lib/rancher/.../opt/cni/bin/cilium-cni` to satisfy kubelet lookup.
4. Observed Cilium BPF compile errors from stale templates in `/var/run/cilium/state/templates` and `/var/lib/cilium/bpf`.
5. Cleared stale state, removed flannel conflist files (`/etc/cni/net.d/10-flannel.conflist`), and restarted Cilium. Endpoint regeneration still degraded and API timeouts persisted.
6. Decided to revert to flannel permanently. Uninstalled Cilium and cleaned up Cilium artifacts (CNI conf & binary symlink, BPF pins, templates), restarted RD.
7. Re-ran `just install-foundation` (installer now defaults to skipping Cilium). Fixed a small installer ordering bug (MetalLB CRDs) in repo.
8. Verified pod-to-pod networking on flannel with BusyBox ping; success.

---

## Cleanup commands used (safe to re-run)

```bash
# Uninstall Cilium (if present)
helm -n kube-system uninstall cilium || true
kubectl -n kube-system delete ds/cilium --ignore-not-found || true

# Remove Cilium CNI conf and binary on node (run via kubectl debug node/... chroot /host)
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl debug node/$NODE -it --image=busybox:1.36 -- chroot /host sh -c '
  rm -f /etc/cni/net.d/05-cilium.conflist /usr/libexec/cni/cilium-cni 2>/dev/null || true
  rm -rf /var/run/cilium/* /var/run/cilium/state/templates/* /var/lib/cilium/bpf/* 2>/dev/null || true
  mountpoint -q /sys/fs/bpf && find /sys/fs/bpf -maxdepth 1 -name "cilium*" -exec rm -rf {} + 2>/dev/null || true
  ls -l /etc/cni/net.d || true
'

# Remove cilium taint if present
kubectl taint nodes --all node.cilium.io/agent-not-ready- || true

# Restart Rancher Desktop from host when required (host shell):
rdctl shutdown && rdctl start
```

---

## Quick troubleshooting checklist (future)

- If pods fail to create with CNI errors, run these checks in order:
  1. `kubectl -n kube-system exec ds/cilium -- cilium status --verbose` (if Cilium present)
  2. `kubectl debug node/$NODE -it --image=busybox:1.36 -- chroot /host sh -c 'ls -l /usr/libexec/cni /etc/cni/net.d'`
  3. Ensure there is only one CNI conflist in `/etc/cni/net.d` (flannel or cilium), not both.
  4. Clear Cilium state if BPF compile/regeneration fails: remove `/var/run/cilium/state/templates/*` and `/var/lib/cilium/bpf/*`, then restart Cilium.
  5. If using Rancher Desktop, always restart RD from host after changing kubelet CNI paths.

---

## Where to look in the repo

- `tools/scripts/install_foundation.sh` — foundation install wrapper, Cilium flags (CILIUM_* env vars)
- `docs/rancher-desktop-cilium.md` — earlier notes & troubleshooting steps
- `deploy/metallb/ipaddresspool.yaml` — MetalLB pool manifest (applied after CRDs)

---

Keep this file updated as you change CNI or do major maintenance. If you want, I can also add a short `just` target that prints this doc or packages the cluster snapshot automatically.
