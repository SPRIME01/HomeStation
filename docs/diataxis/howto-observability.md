# How-To: Operate Observability

Install / update
```bash
just deploy-obs --dry-run  # preview
just deploy-obs            # apply
```
Components
- Loki (SingleBinary + filesystem): simple, no object storage required
- Tempo: traces backend
- Mimir: metrics backend (demo settings)
- Grafana: dashboards and Explore
- OpenTelemetry Collector: receives OTLP and forwards traces to Tempo

Grafana login
- URL: https://grafana.<DOMAIN>
- Default admin password (demo): `admin` (change post-install)

Add data sources (Grafana → Connections)
- Loki: URL `http://loki-gateway.observability.svc.cluster.local/` (use “custom HTTP headers” for multi-tenancy: `X-Scope-OrgID: default`)
- Tempo: URL `http://tempo.observability.svc.cluster.local:3200`
- Mimir (Prometheus): URL `http://mimir-nginx.observability.svc.cluster.local/prometheus`

Collect logs (Promtail)
- Best practice: deploy Promtail only after raising node file-descriptor limits.
- Check current limit: `just promtail-check` (aim for ≥ 1048576)
- Enable Promtail when ready:
```bash
PROMTAIL_ENABLED=1 just deploy-obs
```

Troubleshooting
- Grafana up but no data:
  - Verify data source URLs and access mode (in-cluster service URLs above)
  - Check Loki/Tempo/Mimir pods in `observability`
- Loki install errors about storage/buckets:
  - Use provided `loki-values.yaml` (SingleBinary + filesystem) and keep SSD components at 0
- OTel Collector crash about unknown exporter:
  - Current chart uses `opentelemetry-collector-contrib`; logs exporter is not configured (use Promtail).
- “Too many open files” with Promtail:
  - See `docs/diataxis/guide-promtail-ulimit.md`; raise node `LimitNOFILE`, then redeploy Promtail

Secrets quickstart (Vault + ESO)
- Ensure Vault is initialized/unsealed and you have a token:
  - `just vault-init` and confirm writing `tools/secrets/.envrc.vault`, then `direnv allow .`.
- Seed common app secrets (n8n, RabbitMQ, Flagsmith) into Vault KV:
  - Interactive: `just vault-seed-kv`
  - Only one: `just vault-seed-kv --only n8n` (or `rabbitmq`, `flagsmith`)
  - Generate random values without prompts: `just vault-seed-kv --random`
- Seed a new Nx-generated service APP_SECRET:
  - `just vault-seed <service>` or `just vault-seed <service> --random`
- Vault paths used by this repo:
  - `kv/apps/n8n/app`: `N8N_BASIC_AUTH_PASSWORD`
  - `kv/apps/rabbitmq/app`: `password`, `erlangCookie`
  - `kv/apps/flagsmith/app`: `secret-key`
  - `kv/apps/flagsmith/database`: `url` (set if using external DB)
ESO syncs these into Kubernetes; manifests already reference those Secrets.

How to use:
1. just vault-init and allow .envrc to load tools/secrets/.envrc.vault.
2. Run just vault-seed-kv (or --random) to populate secrets.
3. Deploy as usual: just deploy-core, just deploy-obs, etc. ESO will sync secrets to K8s automatically.
