#!/usr/bin/env bash
# Fills every CHANGE_ME in .env with a freshly generated value.
# Safe to run once; re-running rotates only what is still CHANGE_ME.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { cp .env.example .env; echo "created .env from .env.example"; }
chmod 600 .env

hex()  { openssl rand -hex 32; }
b64()  { openssl rand -base64 32; }
word() { openssl rand -hex 16; }          # URL-safe: no @ : / ? #

set_if_placeholder() {                     # key, value
  local k=$1 v=$2
  grep -q "^$k=CHANGE_ME\s*$" .env || return 0
  # '|' is safe: none of our generated values contain it
  sed -i "s|^$k=CHANGE_ME.*|$k=$v|" .env
  echo "  set $k"
}

for k in JWT_SECRET JWT_DEF_SECRET JWT_SDK_SECRET SESSION_SECRET \
         OIDC_STATE_HMAC_KEY TOTP_ENCRYPTION_KEY SYNC_CONFIG_ENCRYPTION_KEY \
         HYDRA_SECRETS_SYSTEM HYDRA_SECRETS_COOKIE HYDRA_PAIRWISE_SALT; do
  set_if_placeholder "$k" "$(hex)"
done
set_if_placeholder ENCRYPTION_KEY       "$(b64)"
set_if_placeholder VAULT_PASSWORD       "$(word)"
set_if_placeholder MINIO_ROOT_PASSWORD  "$(word)"

# the database password appears twice: raw, and URL-encoded for DSNs
if grep -q '^DB_PASSWORD=CHANGE_ME' .env; then
  pw=$(word)                               # hex, so the two copies are identical
  sed -i "s|^DB_PASSWORD=CHANGE_ME.*|DB_PASSWORD=$pw|" .env
  sed -i "s|^DB_PASSWORD_URLENCODED=.*|DB_PASSWORD_URLENCODED=$pw|" .env
  echo "  set DB_PASSWORD (and its URL-encoded copy)"
fi

left=$(grep -c 'CHANGE_ME' .env || true)
echo
if [[ "$left" -eq 0 ]]; then
  echo "All secrets generated. Now set DOMAIN and the hostnames in .env."
else
  echo "$left placeholder(s) still in .env:"
  grep -n 'CHANGE_ME' .env | sed 's/^/    /'
fi
