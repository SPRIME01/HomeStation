# Troubleshooting

Kubernetes cluster unreachable
- Symptom: `Kubernetes cluster unreachable: Get https://127.0.0.1:6443/version ...`
- Fix: ensure your local k8s distro is running and kubeconfig context is set.
  - Rancher Desktop: see `docs/rancher-desktop-config.md`
  - Check: `kubectl cluster-info`

Helm repo update/network errors
- Symptom: DNS or network sandboxing errors during `helm repo update`
- Fix: verify host DNS and network access. If using a corporate proxy, export proxy env vars for `helm` and `just` shell.

Ingress not reachable by hostname
- Ensure DNS resolves `<host>.<DOMAIN>` to a MetalLB IP in your pool.
- Verify IngressClass is `traefik` and Traefik is running.
- Certificates: `kubectl get cert -A` and inspect for `Ready=True`.

Grafana reachable but no data
- In Grafana, verify data sources:
  - Loki: http://loki-gateway.observability.svc.cluster.local/
  - Tempo: http://tempo.observability.svc.cluster.local:3200
  - Mimir: http://mimir-nginx.observability.svc.cluster.local/prometheus

Loki chart storage/bucket errors
- Use SingleBinary + filesystem mode (`deploy/observability/loki-values.yaml`) and keep SSD components at 0.

OTel Collector “unknown exporter: loki”
- The chart uses the contrib image and does not include Loki exporter by default.
- Remove `loki` exporter from config (use Promtail for logs), keep OTLP → Tempo traces.

Promtail CrashLoopBackOff: too many open files
- Root cause: low per-process `nofile` on the node/container runtime.
- Fix: raise `LimitNOFILE` via systemd overrides (see `docs/diataxis/guide-promtail-ulimit.md`).
- Verify: `just promtail-check` shows ≥ 1048576.

Cloudflare Tunnel errors: missing credentials
- Symptom: `[error] Missing secret infra/cloudflared-credentials`
- Fix: `just cloudflare-tunnel-secret /path/to/credentials.json` (or place at `tools/secrets/cloudflared/credentials.json`).

RabbitMQ/n8n/Flagsmith auth prompts
- n8n may be behind a Traefik basic auth middleware (`deploy/traefik/n8n-auth-middleware.yaml`). Update or remove as needed.

Where to ask for help
- Start with `just doctor` output and attach logs of failing pods: `kubectl logs -n <ns> <pod>`
