Promtail ulimit (Max open files) tuning

Why this matters
- Promtail opens many file descriptors to watch container logs. Low per-process limits (e.g., 1024) can cause crashes: "too many open files".

Best practice
- Raise the container runtime’s open-files limit so pods inherit a high limit (e.g., 1,048,576).

Containerd (systemd)
- Create or edit: /etc/systemd/system/containerd.service.d/override.conf
  [Service]
  LimitNOFILE=1048576
- Then: sudo systemctl daemon-reload && sudo systemctl restart containerd

K3s (systemd)
- Create or edit: /etc/systemd/system/k3s.service.d/override.conf
  [Service]
  LimitNOFILE=1048576
- Then: sudo systemctl daemon-reload && sudo systemctl restart k3s

Rancher Desktop
- Increase file descriptor limits in the underlying distro/VM or update to a version where limits are configurable. If using containerd inside RD, apply the containerd systemd override in the host VM.

Verify in Kubernetes
- Check inside a pod: cat /proc/self/limits | grep -i "open files"
- Expect something like: Max open files 1048576 1048576 files

Enabling Promtail
- Default is disabled in Justfile. Enable when node limits are raised:
  PROMTAIL_ENABLED=1 just deploy-obs

