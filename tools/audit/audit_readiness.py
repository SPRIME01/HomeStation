#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Homelab readiness audit for WSL2 + k3s + Traefik + Vault/ESO + Ory + Supabase + RabbitMQ + LGTM + etc.
Outputs JSON and/or Markdown with PASS/WARN/FAIL + fix hints.

No third-party deps. Python 3.8+.
"""
import argparse, json, platform, re, shutil, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Tuple, Dict, Optional, Mapping

# -------- utility --------
def run(cmd:List[str], timeout:float=10, check:bool=False, capture:bool=True, dry_run:bool=False) -> tuple[int,str]:
    """Run a command returning (rc, output).

    When dry_run=True, we don't execute anything and instead return a sentinel.
    """
    if dry_run:
        return 0, "(dry-run skipped)"
    try:
        if capture:
            out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, timeout=timeout, text=True)
            return 0, out.strip()
        else:
            p = subprocess.run(cmd, timeout=timeout, check=check)
            return p.returncode, ""
    except Exception as e:
        return 1, str(e)

def which(x:str)->str|None:
    return shutil.which(x)

def listen_ports(dry_run:bool=False):
    # Try psutil-free approach: ss -> netstat -> lsof
    for probe in [
        ["ss","-lntp"],["ss","-lnt"],["netstat","-ano"],["lsof","-iTCP","-sTCP:LISTEN","-n","-P"]
    ]:
        if which(probe[0]):
            rc,out = run(probe, dry_run=dry_run)
            if rc==0: return out
    return ""

def is_wsl():
    try:
        with open("/proc/version","r") as f:
            return "microsoft" in f.read().lower()
    except:
        return False

def kget(args:list[str], dry_run:bool=False):
    return run(["kubectl"]+args, timeout=15, dry_run=dry_run)

def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tools/audit/reports", help="output directory")
    ap.add_argument("--format", choices=["json","md","both"], default="both")
    ap.add_argument("--strict", action="store_true", help="exit nonzero if any FAIL")
    ap.add_argument("--dry-run", action="store_true", help="simulate checks without executing external commands")
    return ap.parse_args()

# -------- checks --------
KNOWN_CMDS = {
    # core platform & k8s
    "kubectl": ["kubectl","version","--client","--output=yaml"],
    "helm": ["helm","version","--short"],
    "k3s": ["k3s","--version"],
    "docker": ["docker","--version"],
    "nerdctl": ["nerdctl","--version"],
    "ctr": ["ctr","version"],
    # lightweight k3s binary (if present) separate from server components
    "k3s": ["k3s","--version"],
    # IaC / ops
    "pulumi": ["pulumi","version"],
    "ansible": ["ansible","--version"],
    "argocd": ["argocd","version","--client"],
    # secrets/supply-chain
    "vault": ["vault","version"],
    "sops": ["sops","--version"],
    "age": ["age","--version"],
    "cosign": ["cosign","version"],
    "syft": ["syft","version"],
    "trivy": ["trivy","--version"],
    # dev tooling
    "git": ["git","--version"],
    "node": ["node","-v"],
    "pnpm": ["pnpm","-v"],
    "python3": ["python3","--version"],
    "uv": ["uv","--version"],
    # rancher desktop
    "rdctl": ["rdctl","version"],
    # optional for SSO scale
    "redis-cli": ["redis-cli","--version"],
}

# Ports likely to matter at host level (some will be container/cluster-only)
KNOWN_PORTS = {
    6443: "Kubernetes API (k3s/rancher)",
    9345: "k3s supervisor (join API)",
    80: "Traefik HTTP ingress",
    443: "Traefik HTTPS ingress",
    8080: "ArgoCD local pf / Guacamole alt web",
    8200: "Vault API/UI",
    8201: "Vault cluster",
    3000: "Grafana / Homepage / Semaphore (via Ingress)",
    15672: "RabbitMQ Management (should not be public)",
    15692: "RabbitMQ Prometheus metrics",
    5672: "RabbitMQ AMQP",
    19999: "Netdata",
    4317: "OTel collector gRPC",
    4318: "OTel collector HTTP",
    8000: "Kong (Supabase edge)",
    8443: "Kong TLS (Supabase edge) / Guacamole alt",
    4000: "Supabase Realtime (internal)",
    5000: "Supabase Storage (internal)",
    9999: "Supabase GoTrue (internal)",
    4822: "guacd (internal)",
    4444: "Ory Hydra public",
    4445: "Ory Hydra admin (keep private)",
    4433: "Ory Kratos public",
    4434: "Ory Kratos admin (keep private)",
    5678: "n8n",
}

def status(pass_: Optional[bool]=None, warn:bool=False, msg:str="", fix:str="", skip:bool=False) -> Dict[str,str]:
    if skip:
        level="SKIP"
    elif pass_ is None and warn:
        level="WARN"
    elif pass_:
        level="PASS"
    else:
        level="FAIL"
    return {"level":level,"message":msg,"fix":fix}

def check_os_env() -> List[Tuple[str, Dict[str,str]]]:
    items: List[Tuple[str, Dict[str,str]]] = []
    items.append(("OS", status(True, msg=f"{platform.platform()} (WSL2={is_wsl()})")))
    # systemd present?
    if which("systemctl"):
        rc,out = run(["systemctl","is-system-running"], timeout=5)
        if rc==0 and "running" in out:
            items.append(("systemd", status(True, msg="systemd active")))
        else:
            items.append(("systemd", status(None, warn=True, msg=f"systemd not fully running ({out})", fix="Enable systemd in /etc/wsl.conf and restart WSL")))
    else:
        items.append(("systemd", status(None, warn=True, msg="systemctl not found", fix="Enable systemd in WSL or proceed without it")))
    # virtualization flags
    try:
        with open("/proc/cpuinfo") as f:
            cpu = f.read().lower()
        virt = "vmx" in cpu or "svm" in cpu
        items.append(("virtualization", status(virt, msg="VMX/SVM present" if virt else "No VMX/SVM flags", fix="Enable virtualization in BIOS/UEFI")))
    except:
        items.append(("virtualization", status(None, warn=True, msg="Could not read /proc/cpuinfo")))
    # k3s installation directories (lightweight check)
    k3s_dirs = ["/var/lib/rancher/k3s","/etc/rancher/k3s","/var/lib/kubelet"]
    present = [d for d in k3s_dirs if Path(d).exists()]
    items.append(("k3s-install", status(bool(present), msg=f"found {len(present)}/{len(k3s_dirs)} dirs" if present else "k3s dirs missing", fix="Install k3s via rancher installer or verify permissions")))
    return items

def check_cmds(dry_run:bool=False) -> List[Tuple[str, Dict[str,str]]]:
    rows: List[Tuple[str, Dict[str,str]]] = []
    for name, cmd in KNOWN_CMDS.items():
        if which(cmd[0]):
            if dry_run:
                rows.append((name, status(skip=True, msg="(dry-run skipped)")))
            else:
                rc,out = run(cmd, dry_run=dry_run)
                ok = (rc==0)
                msg = out.splitlines()[0] if out else "ok"
                rows.append((name, status(ok, msg=msg)))
        else:
            rows.append((name, status(False, msg="not installed", fix=f"Install {name} and ensure it is on PATH")))
    return rows

def check_k8s(dry_run:bool=False) -> List[Tuple[str, Dict[str,str]]]:
    rows: List[Tuple[str, Dict[str,str]]] = []
    if not which("kubectl"):
        rows.append(("kubectl", status(False, msg="kubectl not installed")))
        return rows
    if dry_run:
        rows.append(("cluster", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,out = kget(["cluster-info"], dry_run=dry_run)
        rows.append(("cluster", status(rc==0, msg=out if rc!=0 else "cluster reachable", fix="Ensure kubeconfig / KUBECONFIG and k3s/rancher are running")))
        # k3s server version via node query (fallback to binary handled in CLI section)
        rc,nodes = kget(["get","nodes","-o","wide"], dry_run=dry_run)
        if rc==0 and nodes:
            first_line = nodes.splitlines()[1] if len(nodes.splitlines())>1 else nodes.splitlines()[0]
            rows.append(("node-sample", status(True, msg=first_line)))
    # CNI detection (cilium/calico/flannel)
    if dry_run:
        rows.append(("cni", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc, pods = kget(["-n","kube-system","get","pods","-o","name"], dry_run=dry_run)
        cni = "unknown"
        if rc==0:
            if "cilium" in pods: cni="cilium"
            elif "calico" in pods: cni="calico"
            elif "flannel" in pods: cni="flannel"
        rows.append(("cni", status(True, msg=f"{cni}")))
        if cni=="flannel":
            rows.append(("networkpolicy", status(None, warn=True, msg="Flannel does not enforce NetworkPolicies", fix="Switch to Cilium or Calico for policy support")))
    # Traefik
    if dry_run:
        rows.append(("traefik", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc, tsvc = kget(["-n","kube-system","get","svc","-o","wide"], dry_run=dry_run)
        rows.append(("traefik", status(rc==0 and "traefik" in tsvc, msg="Traefik service detected" if rc==0 else "svc list failed")))
    # MetalLB
    if dry_run:
        rows.append(("metallb", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,_ = kget(["get","ns","metallb-system"], dry_run=dry_run)
        rows.append(("metallb", status(rc==0, msg="metallb-system namespace present" if rc==0 else "not installed", fix="Install MetalLB and configure IPAddressPool + L2Advertisement")))
    # ArgoCD
    if dry_run:
        rows.append(("argocd", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,_ = kget(["get","ns","argocd"], dry_run=dry_run)
        rows.append(("argocd", status(rc==0, msg="argocd namespace present" if rc==0 else "not installed", fix="Install Argo CD (GitOps)")))
    # External Secrets Operator
    if dry_run:
        rows.append(("external-secrets", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,_ = kget(["get","crd"], dry_run=dry_run)
        eso_present = (rc==0 and "externalsecrets.external-secrets.io" in _ or "clustersecretstores.external-secrets.io" in _)
        rows.append(("external-secrets", status(eso_present, msg="ESO CRDs found" if eso_present else "ESO not detected", fix="Install External Secrets Operator and configure Vault ClusterSecretStore")))
    # Vault
    if dry_run:
        rows.append(("vault", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,_ = kget(["get","ns","vault"], dry_run=dry_run)
        rows.append(("vault", status(rc==0, msg="vault namespace present" if rc==0 else "not installed", fix="Deploy Vault with Raft + TLS; enable k8s auth")))
    # Ory
    if dry_run:
        rows.append(("ory", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,_ = kget(["get","ns","ory"], dry_run=dry_run)
        rows.append(("ory", status(rc==0, msg="ory namespace present" if rc==0 else "not installed", fix="Deploy Kratos + Hydra and consent UI")))
    # Supabase (namespace or label)
    if dry_run:
        rows.append(("supabase", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,out = kget(["get","ns"], dry_run=dry_run)
        supa = rc==0 and ("supabase" in out.lower() or "data" in out.lower())
        rows.append(("supabase", status(supa, msg="namespace present" if supa else "not detected", fix="Deploy Supabase; expose only Kong (8000/8443)")))
    # RabbitMQ
    if dry_run:
        rows.append(("rabbitmq", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,_ = kget(["get","ns","rabbitmq"], dry_run=dry_run)
        rows.append(("rabbitmq", status(rc==0, msg="rabbitmq namespace present" if rc==0 else "not installed", fix="Deploy RabbitMQ; mgmt internal; metrics 15692")))
    # LGTM / Grafana
    if dry_run:
        rows.append(("observability", status(skip=True, msg="(dry-run skipped)")))
        rows.append(("rancher", status(skip=True, msg="(dry-run skipped)")))
    else:
        rc,out = kget(["get","ns"], dry_run=dry_run)
        lgtm = rc==0 and ("lgtm" in out.lower() or "observability" in out.lower() or "grafana" in out.lower())
        rows.append(("observability", status(lgtm, msg="observability ns present" if lgtm else "not detected", fix="Deploy docker-otel-lgtm (Grafana/Tempo/Loki/Mimir)")))
        rc,out = kget(["get","ns"], dry_run=dry_run)
        rancher = rc==0 and ("cattle-system" in out.lower() or "rancher" in out.lower())
        # If k3s present but rancher absent -> WARN; else FAIL
        if rancher:
            rows.append(("rancher", status(True, msg="rancher/cattle-system ns present")))
            # Try get rancher deployment image version
            rc, dep = kget(["-n","cattle-system","get","deploy","rancher","-o","jsonpath={.spec.template.spec.containers[0].image}"], dry_run=dry_run)
            if rc==0 and dep:
                rows.append(("rancher-version", status(True, msg=dep)))
        else:
            # detect k3s by k3s binary / dirs
            k3s_present = bool(which("k3s")) or Path("/var/lib/rancher/k3s").exists()
            if k3s_present:
                rows.append(("rancher", status(None, warn=True, msg="k3s present, Rancher not detected", fix="Install Rancher for multi-cluster management or ignore if single cluster")))
            else:
                rows.append(("rancher", status(False, msg="not detected", fix="Deploy Rancher (cattle-system) if centralized mgmt desired")))
        # Rancher Desktop specific (rdctl) details
        if which("rdctl"):
            if dry_run:
                rows.append(("rdctl", status(skip=True, msg="(dry-run skipped)")))
            else:
                rc,out = run(["rdctl","version"], dry_run=dry_run)
                rows.append(("rdctl", status(rc==0, msg=out.splitlines()[0] if out else "installed")))
                # Try to fetch embedded k8s node sample via rdctl shell kubectl
                rc, rd_nodes = run(["rdctl","shell","kubectl","get","nodes","-o","wide"], dry_run=dry_run)
                if rc==0 and rd_nodes:
                    lines = rd_nodes.splitlines()
                    if len(lines) > 1:
                        rows.append(("rdctl-node", status(True, msg=lines[1])))
    return rows

def check_ports(dry_run:bool=False) -> List[Tuple[str, Dict[str,str]]]:
    if dry_run:
        # Mark all port checks as skipped
        return [(f"port:{p}", status(skip=True, msg="(dry-run skipped)")) for p in sorted(KNOWN_PORTS.keys())]
    out = listen_ports(dry_run=dry_run)
    rows: List[Tuple[str, Dict[str,str]]] = []
    if not out:
        rows.append(("ports", status(None, warn=True, msg="Could not list listening ports", fix="Install ss or netstat or lsof")))
        return rows
    for p, desc in sorted(KNOWN_PORTS.items()):
        if re.search(rf":{p}\b", out):
            rows.append((f"port:{p}", status(None, warn=True, msg=f"Listening on host: {desc}", fix="If this should be cluster-only, remove host binds and expose via Traefik")))
        else:
            rows.append((f"port:{p}", status(True, msg="no host bind detected")))
    return rows

def summarize(sections: Mapping[str, List[Tuple[str, Dict[str,str]]]]) -> Dict[str,int]:
    summary: Dict[str,int] = {"PASS":0,"WARN":0,"FAIL":0,"SKIP":0}
    for items in sections.values():
        for _, st in items:
            summary[st["level"]] += 1
    return summary

def to_markdown(sections: Mapping[str, List[Tuple[str, Dict[str,str]]]], summary: Mapping[str,int]) -> str:
    def badge(level: str) -> str:
        mapping = {"PASS":"✅","WARN":"⚠️","FAIL":"❌","SKIP":"⏭️"}
        return mapping.get(level, level)
    lines: List[str] = []
    lines.append(f"# Homelab Readiness Report\nGenerated: {datetime.now(timezone.utc).isoformat()}\n")
    lines.append(f"**Summary:** ✅ {summary['PASS']}  ⚠️ {summary['WARN']}  ❌ {summary['FAIL']}  ⏭️ {summary['SKIP']}\n")
    for name, items in sections.items():
        lines.append(f"## {name}")
        lines.append("| Check | Status | Message | Fix Hint |")
        lines.append("|---|---|---|---|")
        for check, st in items:
            lines.append(f"| `{check}` | {badge(st['level'])} {st['level']} | {st['message'].replace('|','/')} | {st['fix'].replace('|','/') if st['fix'] else ''} |")
        lines.append("")
    return "\n".join(lines)

def main():
    args = parse_args()
    outdir = Path(args.out); outdir.mkdir(parents=True, exist_ok=True)

    dry = args.dry_run

    sections = {
        "OS & Platform": check_os_env(),  # local file reads ok in dry-run
        "CLI Tooling": check_cmds(dry_run=dry),
        "Kubernetes": check_k8s(dry_run=dry),
        "Host Ports": check_ports(dry_run=dry),
    }
    summary = summarize(sections)

    data: Dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "dry_run": dry,
        "summary": summary,
        "sections": {k:[{"check":c, **s} for c,s in v] for k,v in sections.items()}
    }

    if args.format in ("json","both"):
        (outdir/"readiness.json").write_text(json.dumps(data, indent=2))
    if args.format in ("md","both"):
        (outdir/"readiness.md").write_text(to_markdown(sections, summary))

    # Exit policy
    if args.strict and summary["FAIL"]>0:
        sys.exit(2)

if __name__=="__main__":
    main()
