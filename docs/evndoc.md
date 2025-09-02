 I've analyzed the project's configuration and secrets management. The Justfile is
   the main entry point, setting environment variables with defaults. It
  orchestrates shell and Python scripts, all of which rely on these environment
  variables. I found no general-purpose .env file; configuration is primarily
  through shell-set environment variables. HashiCorp Vault is used for secrets,
  initialized with vault_init.sh which creates tools/secrets/.envrc.vault for the
  token. The External Secrets Operator, installed by install_foundation.sh, fetches
   secrets from Vault for use in Kubernetes, as confirmed by ExternalSecret
  resources in deploy/flagsmith/deploy.yaml. The project does not use a synergistic
   .env file.





   ----------------------------
   # 1) (optional) install direnv - uncomment the line for your distro
# Debian/Ubuntu:
# sudo apt update && sudo apt install -y direnv
# Fedora:
# sudo dnf install -y direnv
# Arch:
# sudo pacman -Syu direnv

# 2) backup your zshrc
cp ~/.zshrc ~/.zshrc.direnv.bak

# 3) add "direnv" to the plugins=(...) line (if present), or append a plugins line if none
awk 'BEGIN{added=0} /^\s*plugins[[:space:]]*=.*\(/ {
  if ($0 ~ /direnv/) { print; added=1; next }
  sub(/\)/," direnv)"); print; added=1; next
}
{ print }
END { if (!added) print "plugins=(direnv)" }' ~/.zshrc > ~/.zshrc.tmp && mv ~/.zshrc.tmp ~/.zshrc

# 4) add the direnv hook (if missing)
if ! grep -q 'direnv hook zsh' ~/.zshrc; then
  printf '\n# direnv hook - allow direnv to modify the environment\neval "$(direnv hook zsh)"\n' >> ~/.zshrc
fi

# 5) reload zshrc into current shell
source ~/.zshrc

# 6) (in a project dir) remove Markdown fences from .envrc if they exist, ensure it sources the Vault session, allow and test
if [ -f .envrc ]; then sed -i '/^```/d' .envrc; fi
# Ensure .envrc loads the optional Vault session file (written by just vault-init)
grep -q 'source_env_if_exists tools/secrets/.envrc.vault' .envrc 2>/dev/null || \
  printf '%s\n' 'source_env_if_exists tools/secrets/.envrc.vault' >> .envrc
direnv allow .
# verify VAULT envs load if present
echo "VAULT_ADDR=${VAULT_ADDR:-unset}  VAULT_TOKEN=${VAULT_TOKEN:+set}"

# If you ever need to revert, restore the backup:
# cp ~/.zshrc.direnv.bak ~/.zshrc &&
