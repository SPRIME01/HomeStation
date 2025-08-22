 I've analyzed the project's configuration and secrets management. The Justfile is
   the main entry point, setting environment variables with defaults. It
  orchestrates shell and Python scripts, all of which rely on these environment
  variables. I found no general-purpose .env file; configuration is primarily
  through shell-set environment variables. HashiCorp Vault is used for secrets,
  initialized with vault_init.sh which creates tools/secrets/.env.vault for the
  token. The External Secrets Operator, installed by install_foundation.sh, fetches
   secrets from Vault for use in Kubernetes, as confirmed by ExternalSecret
  resources in deploy/flagsmith/deploy.yaml. The project does not use a synergistic
   .env file. 
