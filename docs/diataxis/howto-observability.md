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
