# Rancher Desktop + Cilium: CNI path fix

If you migrate Rancher Desktop (k3s) from flannel to Cilium and see errors like:

```
Failed to create pod sandbox: ... failed to find plugin "cilium-cni" in path [/usr/libexec/cni]
```

The kubelet on the Rancher Desktop VM is hardcoded to `/usr/libexec/cni`. Cilium by default writes to k3s paths. Fix with one of the options below. Option 1 is recommended.

## Option 1 — Reconfigure k3s (recommended)

1) Shell into the Rancher Desktop VM. Run this from your HOST, not inside the VM:

```bash
rdctl shell
```
2) Edit `/etc/rancher/k3s/config.yaml` and set:

```
cni-bin-dir: /var/lib/rancher/k3s/data/agent/bin
cni-conf-dir: /var/lib/rancher/k3s/agent/etc/cni/net.d
```

3) Restart Kubernetes:

Inside the VM (may be a no-op depending on RD version):

```
sudo systemctl restart k3s
```

Exit the VM, then restart Rancher Desktop from the HOST to ensure kubelet picks up the new CNI paths:

```bash
rdctl shutdown
rdctl start
```

## Option 2 — Symlink workaround

```
sudo mkdir -p /usr/libexec/cni
sudo ln -sf /var/lib/rancher/k3s/data/agent/bin/cilium-cni /usr/libexec/cni/cilium-cni
sudo systemctl restart k3s
```

## Option 3 — Install Cilium to kubelet path

You can force this repo to install Cilium into the kubelet's expected directories:

```
export CILIUM_CNI_BIN_PATH=/usr/libexec/cni
export CILIUM_CNI_CONF_PATH=/etc/cni/net.d
just install-foundation
```

This sets the Helm flags `--set cni.binPath` and `--set cni.confPath` accordingly via `tools/scripts/install_foundation.sh`.

## Verify

- `kubectl -n kube-system get pods -l k8s-app=cilium`
- Run a quick pod:

```
kubectl run test-pod --image=nginx --rm -it --restart=Never -- echo "CNI Test"
```

- Launch two busybox pods and `ping` between them to confirm pod networking.

Note for WSL: All `rdctl` commands must be executed from the HOST shell, not inside the `rdctl shell` session. If `rdctl` errors inside the VM, exit and run it on the host.

## Troubleshooting: Cilium running but pods not Ready

If `cilium` DaemonSet shows Running but your BusyBox pods time out waiting for Ready, walk these checks in order.

1) Get pod events (CNI hints)

```sh
kubectl describe pod pod-a pod-b | sed -n '/Events/,$p'
```

Look for:
- failed to find plugin "cilium-cni" in path [/usr/libexec/cni]
- Failed to create pod sandbox … CNI plugin not initialized

2) Check Cilium health

```sh
kubectl -n kube-system exec ds/cilium -- cilium status --verbose
kubectl -n kube-system logs ds/cilium -c cilium-agent --tail=200
```

If you see BPF macro redefinition errors or repeated regeneration failures, reset state in step 4.

3) Verify CNI binary and config on the node (works on any k8s, incl. RD)

```sh
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl debug node/$NODE -it --image=busybox:1.36 -- chroot /host sh -c '
	set -x;
	ls -l /usr/libexec/cni/cilium-cni || true;
	echo "--- /etc/cni/net.d:"; ls -l /etc/cni/net.d || true;
	echo "--- list configs:"; grep -R "" -n /etc/cni/net.d 2>/dev/null | sed -n "1,200p" || true;
'
```

Expect:
- A file or symlink at `/usr/libexec/cni/cilium-cni`.
- Only a Cilium conflist in `/etc/cni/net.d` (no flannel/calico leftovers).

4) Fix common causes and restart datapath

- If the CNI binary is missing on RD, either:
	- Reinstall Cilium to kubelet paths (simple):

		```sh
		export CILIUM_CNI_BIN_PATH=/usr/libexec/cni
		export CILIUM_CNI_CONF_PATH=/etc/cni/net.d
		just install-foundation
		```

	- Or create a symlink to the actual binary (advanced):

		```sh
		NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
		kubectl debug node/$NODE -it --image=busybox:1.36 -- chroot /host sh -c '
			set -e;
			dst=/usr/libexec/cni/cilium-cni;
			src=$(find /var/lib/rancher -type f -name cilium-cni | head -n1);
			mkdir -p /usr/libexec/cni;
			[ -n "$src" ] && ln -sf "$src" "$dst" && ls -l "$dst" || { echo "cilium-cni not found"; exit 1; };
		'
		```

- Clear stale Cilium BPF/templates and restart Cilium:

	```sh
	NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
	kubectl debug node/$NODE -it --image=busybox:1.36 -- chroot /host sh -c '
		rm -rf /var/run/cilium/state/templates/* /var/lib/cilium/bpf/* 2>/dev/null || true;
	'
	kubectl -n kube-system delete pod -l k8s-app=cilium
	```

	On Rancher Desktop specifically, if kubelet previously used wrong paths, restart RD from the host after the above:

	```sh
	rdctl shutdown && rdctl start
	```

5) Retest minimal networking

```sh
kubectl run pod-a --image=busybox:1.36 --restart=Never --command -- sh -c 'sleep 3600'
kubectl run pod-b --image=busybox:1.36 --restart=Never --command -- sh -c 'sleep 3600'
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=180s || {
	kubectl describe pod pod-a; kubectl describe pod pod-b;
}
AIP=$(kubectl get pod pod-a -o jsonpath='{.status.podIP}')
kubectl exec pod-b -- ping -c 2 "$AIP"
kubectl delete pod pod-a pod-b --ignore-not-found
```

If pods still don’t become Ready, re-check that only a single Cilium CNI conf exists in `/etc/cni/net.d` and that `cilium status` reports all subsystems OK.

