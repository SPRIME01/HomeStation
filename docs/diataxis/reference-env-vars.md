# Reference: Environment variables

- `INSTALL_DRY_RUN` (0|1): print actions without changes. All recipes accept `--dry-run`.
- `N8N_CHART_VERSION` (default 1.15.2): version for community-charts/n8n.
- `N8N_USE_COMMUNITY_VALUES` (0|1): if 1, pass `deploy/n8n/community-values.yaml` to Helm.
- `TLS_PUBLIC_DOMAIN`: if set (e.g., `primefam.cloud`), foundation applies Cloudflare issuers and wildcard.
- `ACME_EMAIL`: email for Let’s Encrypt account (used with Cloudflare issuer).
- `CF_API_TOKEN`: Cloudflare API token with Zone.DNS:Edit for `TLS_PUBLIC_DOMAIN`. You can store it in `tools/secrets/.envrc.cloudflare` and run `direnv allow .`.
- `HELM_NO_CREDS` (0|1): bypass host keychain (OCI pulls). Used during Bitnami fallbacks.
- `ADOPT_EXISTING` (0|1): annotate/label existing resources for Helm adoption (advanced).

Precedence and examples (.env vs .env.local)
- `.envrc` loads `.env` first, then `.env.local` (if present). Variables in `.env.local` override `.env`.
- `.env` and `.env.local` are gitignored in this repo. Commit examples in `.env.example` only.
- Example `.env.example` (copy to `.env` locally):
  - `DOMAIN=homelab.lan`
  - `PROMTAIL_ENABLED=0`
- Example `.env.local` (overrides for your machine):
  - `DOMAIN=primefam.cloud`
  - `PROMTAIL_ENABLED=1`
