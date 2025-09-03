import * as fs from 'fs';
import * as path from 'path';
export interface Schema { name: string; }
export async function serviceGenerator(_tree: any, schema: Schema) {
  const name = schema.name;
  const base = path.join('apps', name);
  const mkdirp = (p: string) => fs.mkdirSync(p, { recursive: true });
  const files: [string,string][] = [
    ['main.py', `from fastapi import FastAPI
app = FastAPI()
@app.get("/")
def hello():
    return {"service":"${name}","status":"ok"}
`],
    ['pyproject.toml', `[project]
name = "${name}"
version = "0.1.0"
dependencies = ["fastapi","uvicorn[standard]","opentelemetry-sdk","opentelemetry-instrumentation-fastapi"]
`],
    ['Dockerfile', `FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml .
RUN pip install --no-cache-dir fastapi uvicorn[standard] opentelemetry-sdk opentelemetry-instrumentation-fastapi
COPY . .
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8080"]
`],
    ['k8s/deployment.yaml', `apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: core
spec:
  replicas: 1
  selector: { matchLabels: { app: ${name} } }
  template:
    metadata: { labels: { app: ${name} } }
    spec:
      containers:
        - name: ${name}
          image: ghcr.io/your/${name}:latest
          ports: [{ containerPort: 8080 }]
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector.observability.svc.cluster.local:4318
          envFrom:
            - secretRef: { name: ${name}-secrets }
---
apiVersion: v1
kind: Service
metadata: { name: ${name}, namespace: core }
spec:
  selector: { app: ${name} }
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: core
  annotations: { kubernetes.io/ingress.class: traefik }
spec:
  rules:
    - host: ${name}.homelab.lan
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: ${name}, port: { number: 80 } } }
  tls:
    - hosts: [${name}.homelab.lan]
      secretName: ${name}-tls
`],
    ['k8s/externalsecret.yaml', `apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${name}-externalsecret
  namespace: core
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: vault-kv }
  target: { name: ${name}-secrets }
  data:
    - secretKey: APP_SECRET
      remoteRef: { key: kv/apps/${name}/APP_SECRET }
`]
  ];
  mkdirp(base);
  for (const [rel, content] of files) {
    const fp = path.join(base, rel); mkdirp(path.dirname(fp));
    fs.writeFileSync(fp, content);
  }
  console.log(`Generated service '${name}' in ${base}`);
  console.log(`Next steps:`);
  console.log(`  1) Seed Vault secret for this service: just vault-seed ${name} --random`);
  console.log(`     (ExternalSecret expects: kv/apps/${name}/APP_SECRET with key APP_SECRET)`);
  console.log(`  2) Apply k8s manifests (Deployment/Service/Ingress/ExternalSecret) when ready.`);
}
