#!/usr/bin/env bash
set -euo pipefail

SKIP_CILIUM=${SKIP_CILIUM:-false}
INSTALL_DRY_RUN=${INSTALL_DRY_RUN:-0}
METALLB_PURGE=${METALLB_PURGE:-0}
METALLB_ADOPT=${METALLB_ADOPT:-0}
ADOPT_EXISTING=${ADOPT_EXISTING:-0}
METALLB_GENERATE_POOL=${METALLB_GENERATE_POOL:-0}
METALLB_POOL_START=${METALLB_POOL_START:-192.168.0.240}
METALLB_POOL_END=${METALLB_POOL_END:-192.168.0.250}
GITOPS_BOOTSTRAP=${GITOPS_BOOTSTRAP:-0}
SKIP_ARGOCD=${SKIP_ARGOCD:-0}
NAMESPACE_INFRA=${NAMESPACE_INFRA:-infra}
NAMESPACE_SSO=${NAMESPACE_SSO:-sso}
NAMESPACE_CORE=${NAMESPACE_CORE:-core}
NAMESPACE_OBS=${NAMESPACE_OBS:-observability}
CILIUM_KUBE_PROXY_REPLACEMENT_DEFAULT=${CILIUM_KUBE_PROXY_REPLACEMENT_DEFAULT:-true}

say(){ printf '%s\n' "$*"; }
run(){ if [ "$INSTALL_DRY_RUN" = "1" ]; then echo "(dry-run) $*"; else eval "$@"; fi }
exists(){ command -v "$1" >/dev/null 2>&1; }

# Generic adoption function
# Args: release namespace pattern cluster_kinds namespaced_kinds [specific_crds]
adopt_release_resources(){
  local release="$1" ns="$2" pattern="$3" cluster_kinds="$4" namespaced_kinds="$5" specific_crds="${6:-}"
  [ "$ADOPT_EXISTING" = "1" ] || return 0
  say "[adopt] ${release}: scanning for pre-existing resources"
  # Specific CRDs list (space separated names) if provided
  if [ -n "$specific_crds" ]; then
    for crd in $specific_crds; do
      if kubectl get crd "$crd" >/dev/null 2>&1; then
        run "kubectl annotate crd/${crd} meta.helm.sh/release-name=${release} meta.helm.sh/release-namespace=${ns} --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label crd/${crd} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
      fi
    done
  fi
  # Cluster-scoped kinds (comma or space separated)
  for kind in $(echo "$cluster_kinds" | tr ',' ' '); do
    # Some kinds may not exist in the API; ignore errors
    local list
    list=$(kubectl get $kind -o name 2>/dev/null | grep -E "$pattern" || true)
    for obj in $list; do
      run "kubectl annotate ${obj} meta.helm.sh/release-name=${release} meta.helm.sh/release-namespace=${ns} --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${obj} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
    done
  done
  # Namespaced kinds
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    for kind in $(echo "$namespaced_kinds" | tr ',' ' '); do
      local list
      list=$(kubectl get -n "$ns" $kind -o name 2>/dev/null | grep -E "$pattern" || true)
      for obj in $list; do
        run "kubectl annotate ${obj} -n ${ns} meta.helm.sh/release-name=${release} meta.helm.sh/release-namespace=${ns} --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${obj} -n ${ns} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
      done
    done
  fi
}

# Detect existing CNI by checking common DaemonSets / pods
detect_cni(){
  local ds ns="kube-system"
  for ds in cilium cilium-agent calico-node canal flannel kube-flannel-ds weave-net antrea-agent kube-router ovn-kubernetes; do
    if kubectl get ds -n kube-system "$ds" >/dev/null 2>&1; then
      echo "$ds"; return 0; fi
  done
  if kubectl get pods -n kube-system -o name 2>/dev/null | grep -E '(cilium|flannel|calico|weave|antrea|kube-router|ovn)' >/dev/null; then
    kubectl get pods -n kube-system -o name | grep -E '(cilium|flannel|calico|weave|antrea|kube-router|ovn)' | head -n1 | sed 's#.*/##'; return 0; fi
  return 1
}

existing_cni=$(detect_cni || true)
if echo "$existing_cni" | grep -q '^\['; then existing_cni=""; fi

# Namespaces
for ns in "$NAMESPACE_INFRA" "$NAMESPACE_SSO" "$NAMESPACE_CORE" "$NAMESPACE_OBS"; do
  run "kubectl get ns $ns >/dev/null 2>&1 || kubectl create ns $ns"
done

if [ "$GITOPS_BOOTSTRAP" = "1" ]; then
  say "[mode] GitOps bootstrap enabled (GITOPS_BOOTSTRAP=1): direct helm installs for app components will be skipped; ArgoCD will reconcile them via Applications."
fi

# Cilium (only if not skipped)
if [ "$SKIP_CILIUM" != "true" ]; then
  if [ -n "$existing_cni" ] && echo "$existing_cni" | grep -v cilium >/dev/null; then
    say "[cni] Detected existing CNI '$existing_cni'. Automated in-place migration to Cilium is not attempted. Set FORCE_CILIUM=1 to try anyway after manual prep. Skipping Cilium install."
  else
    # Decide boolean kubeProxyReplacement expected by newer charts
    if kubectl get ds -n kube-system kube-proxy >/dev/null 2>&1; then
      if [ "${FORCE_KPR:-0}" = "1" ]; then
        kpr_mode=${CILIUM_KUBE_PROXY_REPLACEMENT_DEFAULT}
      else
        # Leave kube-proxy in place => kubeProxyReplacement=false
        kpr_mode=false
      fi
    else
      # No kube-proxy DaemonSet => enable replacement
      kpr_mode=${CILIUM_KUBE_PROXY_REPLACEMENT_DEFAULT}
    fi
    say "Installing Cilium (kubeProxyReplacement=$kpr_mode)"
    run "helm upgrade --install cilium cilium/cilium -n kube-system \
      --set kubeProxyReplacement=$kpr_mode \
      --set cgroup.autoMount.enabled=true \
      --set cgroup.hostRoot=/sys/fs/cgroup || true"
    # Wait for Cilium readiness to avoid downstream timeouts (e.g., ArgoCD hooks) if possible
    if [ "$INSTALL_DRY_RUN" != "1" ]; then
      say "[cilium] Waiting for DaemonSet readiness (timeout 300s)"
      if ! kubectl rollout status ds/cilium -n kube-system --timeout=300s >/dev/null 2>&1; then
        say "[warn] Cilium did not become Ready within timeout; subsequent installs may time out (node taint node.cilium.io/agent-not-ready)."
      fi
    fi
  fi
else
  # Broaden detection for flannel in k3s/rancher-desktop (daemonset name may differ)
  if [ -z "$existing_cni" ]; then
    if kubectl get ds -n kube-system | grep -E 'flannel|kube-flannel' >/dev/null 2>&1; then
      existing_cni=flannel
    fi
  fi
  if [ -z "$existing_cni" ]; then
    say "[warning] No CNI detected; SKIP_CILIUM=true. If using Rancher Desktop this may be a detection gap (flannel)."
  else
    say "Skipping Cilium install (SKIP_CILIUM=true, detected CNI '$existing_cni')."
  fi
fi

if [ "$GITOPS_BOOTSTRAP" != "1" ]; then
  # --- MetalLB ---
  say "[metallb] Preflight..."
  if kubectl get ns metallb-system >/dev/null 2>&1; then
    if [ "$METALLB_PURGE" = "1" ]; then
      say "[metallb] Purging namespace metallb-system (METALLB_PURGE=1)"
      run "kubectl delete ns metallb-system"
      if [ "$INSTALL_DRY_RUN" != "1" ]; then
        printf '[metallb] Waiting for namespace deletion...'
        for i in $(seq 1 30); do kubectl get ns metallb-system >/dev/null 2>&1 || { echo ' done'; break; }; sleep 1; printf '.'; done; echo
      fi
    fi
  fi
  if [ "$METALLB_ADOPT" = "1" ] && kubectl get ns metallb-system >/dev/null 2>&1; then
    say "[metallb] Adopting existing namespaced + cluster resources"
    if [ "$INSTALL_DRY_RUN" = "1" ]; then ANN_PREFIX="(dry-run)"; else ANN_PREFIX=""; fi
    # namespaced
    for R in $(kubectl get -n metallb-system all,cm,sa,secret -o name 2>/dev/null || true); do
      run "kubectl annotate ${R} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"
      [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${R} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
    done
    # cluster scoped
    for CRD in $(kubectl get crd -o name 2>/dev/null | grep metallb.io || true); do run "kubectl annotate ${CRD} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CRD} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    for CR in $(kubectl get clusterrole -o name 2>/dev/null | grep metallb || true); do run "kubectl annotate ${CR} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CR} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    for CRB in $(kubectl get clusterrolebinding -o name 2>/dev/null | grep metallb || true); do run "kubectl annotate ${CRB} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CRB} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
  fi
  if [ "$ADOPT_EXISTING" = "1" ]; then
    for CRD in $(kubectl get crd -o name 2>/dev/null | grep metallb.io || true); do run "kubectl annotate ${CRD} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CRD} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    # Also adopt clusterroles / bindings if they remain after a purge
    for CR in $(kubectl get clusterrole -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${CR} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CR} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    for CRB in $(kubectl get clusterrolebinding -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${CRB} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CRB} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    if kubectl get ns metallb-system >/dev/null 2>&1; then
      for R in $(kubectl get role -n metallb-system -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${R} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${R} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
      for RB in $(kubectl get rolebinding -n metallb-system -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${RB} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${RB} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
      for SA in $(kubectl get sa -n metallb-system -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${SA} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${SA} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
      for DEP in $(kubectl get deploy -n metallb-system -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${DEP} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${DEP} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
      for DS in $(kubectl get ds -n metallb-system -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${DS} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${DS} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
      for CM in $(kubectl get cm -n metallb-system -o name 2>/dev/null | grep -E 'metallb' || true); do run "kubectl annotate ${CM} -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${CM} -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    fi
  fi
  if [ "$ADOPT_EXISTING" = "1" ]; then
    for w in $(kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io -o name 2>/dev/null | grep metallb-webhook-configuration || true); do
      run "kubectl annotate $w meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label $w app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    for w in $(kubectl get mutatingwebhookconfigurations.admissionregistration.k8s.io -o name 2>/dev/null | grep metallb || true); do
      run "kubectl annotate $w meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label $w app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
  fi

  adopt_metallb_cluster_scoped(){
    say "[metallb] Adopting cluster-scoped resources (fallback)"; local any=0
    for kind in clusterrole clusterrolebinding validatingwebhookconfigurations.admissionregistration.k8s.io mutatingwebhookconfigurations.admissionregistration.k8s.io; do
      for obj in $(kubectl get ${kind} -o name 2>/dev/null | grep -E 'metallb' || true); do
        any=1; run "kubectl annotate ${obj} meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label ${obj} app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    done
    [ $any -eq 0 ] && say "[metallb] No cluster-scoped objects found to adopt"
  }

  adopt_metallb_namespaced(){
    kubectl get ns metallb-system >/dev/null 2>&1 || return 0
    say "[metallb] Adopting namespaced resources (fallback)"; local kinds="sa,cm,svc,deployment.apps,daemonset.apps,role.rbac.authorization.k8s.io,rolebinding.rbac.authorization.k8s.io" any=0
    for r in $(kubectl get -n metallb-system ${kinds} -o name 2>/dev/null | grep -E 'metallb' || true); do
      any=1; run "kubectl annotate $r -n metallb-system meta.helm.sh/release-name=metallb meta.helm.sh/release-namespace=metallb-system --overwrite >/dev/null 2>&1"; [ "$INSTALL_DRY_RUN" = "1" ] || kubectl label $r -n metallb-system app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true; done
    [ $any -eq 0 ] && say "[metallb] No namespaced objects found to adopt"
  }

  if [ -f deploy/metallb/ipaddresspool.yaml ]; then
    run "kubectl apply -f deploy/metallb/ipaddresspool.yaml"
  elif [ "$METALLB_GENERATE_POOL" = "1" ]; then
    mkdir -p deploy/metallb
    cat > deploy/metallb/ipaddresspool.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_POOL_START}-${METALLB_POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
EOF
    run "kubectl apply -f deploy/metallb/ipaddresspool.yaml"
  else
    echo "[warn] missing deploy/metallb/ipaddresspool.yaml (skipping)"
  fi

  if ! run "helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace"; then
    if [ "$INSTALL_DRY_RUN" = "1" ]; then
      say "[metallb] (dry-run) would retry helm install after adoption"
    else
      if helm status metallb -n metallb-system >/dev/null 2>&1; then
        say "[metallb] Helm release exists despite error; continuing"
      else
        say "[metallb] Helm install failed — attempting adoption + retry"
        adopt_metallb_cluster_scoped; adopt_metallb_namespaced || true
        helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
      fi
    fi
  fi
else
  say "[metallb] Skipping direct install (GitOps bootstrap mode)"
fi

if [ "$GITOPS_BOOTSTRAP" != "1" ]; then
  adopt_release_resources \
    vault "$NAMESPACE_INFRA" 'vault' \
    'clusterrole,clusterrolebinding,validatingwebhookconfigurations.admissionregistration.k8s.io,mutatingwebhookconfigurations.admissionregistration.k8s.io' \
    'sa,role,rolebinding,cm,secret,svc,deploy,statefulset,daemonset,ingress,job,cronjob,pdb,networkpolicy,horizontalpodautoscaler.autoscaling'
  run "helm upgrade --install vault hashicorp/vault -n $NAMESPACE_INFRA" || true
else
  say "[vault] Skipping direct install (GitOps bootstrap mode)"
fi

# ArgoCD adoption (generalized)
if [ "$SKIP_ARGOCD" != "1" ]; then
  adopt_release_resources \
    argocd argocd 'argocd' \
    'clusterrole,clusterrolebinding,validatingwebhookconfigurations.admissionregistration.k8s.io,mutatingwebhookconfigurations.admissionregistration.k8s.io' \
    'sa,role,rolebinding,cm,secret,svc,deploy,statefulset,daemonset,ingress,job,cronjob,pdb,networkpolicy,servicemonitor.monitoring.coreos.com,prometheusrule.monitoring.coreos.com,horizontalpodautoscaler.autoscaling' \
    'applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io argocdextensions.argoproj.io'
  if [ ! -f deploy/argocd/values.yaml ]; then
    mkdir -p deploy/argocd
    cat > deploy/argocd/values.yaml <<'EOF'
redis:
  secretInit:
    tolerations:
      - key: "node.cilium.io/agent-not-ready"
        operator: "Exists"
        effect: "NoSchedule"
controller:
  tolerations:
    - key: "node.cilium.io/agent-not-ready"
      operator: "Exists"
      effect: "NoSchedule"
repoServer:
  tolerations:
    - key: "node.cilium.io/agent-not-ready"
      operator: "Exists"
      effect: "NoSchedule"
server:
  tolerations:
    - key: "node.cilium.io/agent-not-ready"
      operator: "Exists"
      effect: "NoSchedule"
applicationSet:
  tolerations:
    - key: "node.cilium.io/agent-not-ready"
      operator: "Exists"
      effect: "NoSchedule"
notifications:
  tolerations:
    - key: "node.cilium.io/agent-not-ready"
      operator: "Exists"
      effect: "NoSchedule"
EOF
  fi
  run "helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f deploy/argocd/values.yaml" || true
else
  say "[argocd] Skipping ArgoCD install (SKIP_ARGOCD=1). In GitOps mode you must supply ArgoCD by other means."
fi

say "Foundation install sequence complete (dry-run=$INSTALL_DRY_RUN)."

# Post-install summary (skip most kubectl queries during dry-run)
echo
say "===== Post-Install Summary ====="
say "Mode: GitOps_BOOTSTRAP=$GITOPS_BOOTSTRAP | Dry-run=$INSTALL_DRY_RUN"
if [ "$INSTALL_DRY_RUN" != "1" ]; then
  say "Namespaces:"
  kubectl get ns "$NAMESPACE_INFRA" "$NAMESPACE_SSO" "$NAMESPACE_CORE" "$NAMESPACE_OBS" 2>/dev/null || true
  if [ "$SKIP_ARGOCD" != "1" ]; then
    if kubectl get ns argocd >/dev/null 2>&1; then
      svc_host=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      svc_port=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.ports[?(@.name=="https")].port}' 2>/dev/null || echo 443)
      say "ArgoCD: namespace present. Service LB IP: ${svc_host:-<pending>} Port: ${svc_port:-443}"
      say "ArgoCD admin password (initial): kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo" || true
    else
      say "ArgoCD: namespace not found"
    fi
  fi
  if [ "$GITOPS_BOOTSTRAP" != "1" ]; then
    if kubectl api-resources | grep -i ipaddresspool >/dev/null 2>&1; then
      say "MetalLB IPAddressPools:"; kubectl -n metallb-system get ipaddresspools.metallb.io 2>/dev/null || kubectl -n metallb-system get ipaddresspools 2>/dev/null || say "(none)"
    else
      say "MetalLB CRDs not yet present"
    fi
  else
    say "MetalLB handled by GitOps (skipped direct install)."
  fi
else
  say "(dry-run) Skipped cluster introspection."
fi

