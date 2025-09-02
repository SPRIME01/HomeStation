# How-To: Add a new public host

Goal: expose an internal service at `app.primefam.cloud` via Traefik + Cloudflare Tunnel.

Steps
1. Create a Kubernetes Service and Ingress in the `core` namespace (example port 8080):
```yaml
apiVersion: v1
kind: Service
metadata: { name: app, namespace: core }
spec:
  selector: { app: app }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
  namespace: core
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
spec:
  ingressClassName: traefik
  rules:
    - host: app.primefam.cloud
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: app, port: { number: 8080 } }
```
2. Add a route in Cloudflare Tunnel config:
```yaml
  - hostname: app.primefam.cloud
    service: http://traefik.kube-system.svc.cluster.local:80
```
3. Apply updates:
```bash
kubectl -n infra apply -f deploy/cloudflared/config.yaml
```

Notes
- Certificates are managed by cert-manager (wildcard). Traefik terminates TLS.
- You can add Traefik middlewares for auth/rate-limit as needed.
