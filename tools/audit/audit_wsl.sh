#!/usr/bin/env bash
# Compatible with bash and zsh (POSIX-ish where possible) and supports dry-run via DRY_RUN=1

# Enable safe modes if available (zsh doesn't like 'pipefail' via 'set -o pipefail' in sh emulation)
if (set -o pipefail 2>/dev/null); then
  set -euo pipefail
else
  set -euo noglob
fi

DRY_RUN=${DRY_RUN:-0}

log() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] $*"; return 0
  fi
  # shellcheck disable=SC2068
  "$@"
}

header() { log "== $* =="; }

header "Quick WSL2 + k8s audit"

# WSL detection
if grep -qi microsoft /proc/version 2>/dev/null; then
  log "WSL: detected"
else
  log "WSL: not detected (running on native Linux?)"
fi

# systemd?
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-system-running --quiet 2>/dev/null; then
    log "systemd: running"
  else
    log "systemd: present but not fully running"
  fi
else
  log "systemd: not available"
fi

# Core CLIs (no failures on missing)
CLIS="kubectl helm pulumi ansible vault sops age argocd node pnpm uv git rdctl"
for c in $CLIS; do
  if command -v "$c" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      v="(dry-run skipped)"
    else
      v=$("$c" --version 2>/dev/null | head -n1 || echo "ok")
    fi
    log "cli:$c -> $v"
  else
    log "cli:$c -> MISSING"
  fi
done

# Cluster touch (skipped in dry-run)
if command -v kubectl >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    log "kubectl cluster-info (dry-run)"
    log "cni: (dry-run)"
  else
    run kubectl cluster-info || true
    log "namespaces:"
    run kubectl get ns | awk '{print $1}' | tail -n +2 | tr '\n' ' '; echo
    log "services type=LoadBalancer:"
    run kubectl get svc -A | awk '$5=="LoadBalancer"{print $1"/"$2" -> "$4}'
    # Show first node line (version hint)
    if run kubectl get nodes -o wide >/tmp/k8s_nodes.$$ 2>/dev/null; then
      head -n2 /tmp/k8s_nodes.$$ | tail -n1 | sed 's/^/node-sample: /'
      rm -f /tmp/k8s_nodes.$$
    fi
    # Rancher / cattle-system (namespace + rdctl if Rancher Desktop)
    if run kubectl get ns cattle-system >/dev/null 2>&1; then
      log "rancher: cattle-system namespace present"
      # rancher version
      if run kubectl -n cattle-system get deploy rancher -o jsonpath='{.spec.template.spec.containers[0].image}' >/tmp/rancher_img.$$ 2>/dev/null; then
        log "rancher-version: $(cat /tmp/rancher_img.$$)"
        rm -f /tmp/rancher_img.$$
      fi
    elif run kubectl get ns rancher-system >/dev/null 2>&1; then
      log "rancher: rancher-system namespace present"
    fi
    # Rancher Desktop CLI
    if command -v rdctl >/dev/null 2>&1; then
      if run rdctl version >/tmp/rd_ver.$$ 2>/dev/null; then
        log "rdctl: $(head -n1 /tmp/rd_ver.$$)"; rm -f /tmp/rd_ver.$$ || true
      else
        log "rdctl: installed (version query failed)"
      fi
      # optional: show container runtime / k8s status
      if run rdctl shell kubectl get nodes -o wide >/tmp/rd_nodes.$$ 2>/dev/null; then
        head -n2 /tmp/rd_nodes.$$ | tail -n1 | sed 's/^/rdctl-node: /'
        rm -f /tmp/rd_nodes.$$ || true
      fi
    else
      log "rdctl: not found"
    fi
  fi
fi

# Presence checks (skip heavy queries in dry-run)
if [ "$DRY_RUN" = "1" ]; then
  log "Traefik: (dry-run)"
  log "MetalLB: (dry-run)"
  log "External Secrets: (dry-run)"
  log "Rancher: (dry-run)"
  log "Ports: (dry-run skipped)"
else
  kubectl get svc -n kube-system 2>/dev/null | grep -i traefik >/dev/null && log "Traefik: OK" || log "Traefik: not found"
  kubectl get ns metallb-system >/dev/null 2>&1 && log "MetalLB: OK" || log "MetalLB: not found"
  kubectl get crd 2>/dev/null | grep -q externalsecrets && log "External Secrets: OK" || log "External Secrets: not found"
  kubectl get ns cattle-system >/dev/null 2>&1 && log "Rancher: OK (cattle-system)" || kubectl get ns rancher-system >/dev/null 2>&1 && log "Rancher: OK (rancher-system)" || log "Rancher: not found"
  if command -v rdctl >/dev/null 2>&1; then
    rdctl version 2>/dev/null | head -n1 | sed 's/^/Rancher Desktop CLI: /'
  fi
fi

header "Quick audit done"
