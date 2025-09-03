# Guide: direnv for env and secrets

Goals
- Keep secrets out of the repo and shell profiles.
- Make per-project env painless: enter the folder and everything is ready.
- Avoid tech debt by centralizing patterns and keeping them minimal.

What’s already in place
- Secrets live in Vault; Kubernetes gets them via External Secrets Operator.
- `just vault-init` can write a short-lived session file at `tools/secrets/.envrc.vault`.
- `.envrc` loads the Vault session and optional Cloudflare token.

Recommended usage
- Non-secrets: copy `.env.example` to `.env` locally (both `.env` and `.env.local` are gitignored) and put developer defaults there; overrides go in `.env.local`.
- Vault session: run `just vault-init` and choose to write `tools/secrets/.envrc.vault` (chmod 600). `.envrc` auto-loads it.
- Cloudflare: copy `tools/secrets/.envrc.cloudflare.example` to `tools/secrets/.envrc.cloudflare` and set `CF_API_TOKEN=...` only when needed for `just cf-dns-secret`.

Security best practices
- Do not commit `.env.local`, `tools/secrets/.envrc.vault`, or `tools/secrets/.envrc.cloudflare`.
- Keep `.env` free of secrets; use it only for safe defaults (domains, flags).
- If you don’t want `.envrc` to check Vault token health, set `DIRENV_SKIP_VAULT_CHECK=1`.

Quality of life
- `.envrc` watches `tools/secrets/*.envrc*` and `.env*`; `direnv` auto-reloads on changes.
- Variables set via `.env`/`.env.local` flow into Justfile’s `env_var_or_default` without editing the Justfile.

Minimal workflow
1) Install direnv and hook your shell.
2) In the project, run `direnv allow .` once.
3) Copy `.env.example` → `.env` and adjust non-secrets as needed.
4) Optional: `just vault-init` to export a session and write `tools/secrets/.envrc.vault`.
5) Optional: set `CF_API_TOKEN` in `tools/secrets/.envrc.cloudflare` for the cert-manager helper.

Notes
- `.envrc` runs for your shell; it doesn’t put secrets in the repo or in container images.
- For app/runtime secrets, prefer Vault + External Secrets, not `.env` files.
