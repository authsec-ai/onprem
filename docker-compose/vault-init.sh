#!/usr/bin/env bash
# =============================================================================
#  Initialise and unseal Vault, then print the token for .env
# =============================================================================
#  Run once, after "docker compose up -d vault":
#      ./vault-init.sh
#
#  It initialises Vault (a single unseal key), unseals it, enables a KV store,
#  creates a token for the AuthSec services, and writes the unseal key and root
#  token to ./vault-keys.txt.
#
#  Re-running is safe: an already-initialised Vault is only unsealed, which is
#  what you need after the host reboots.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

KEYS_FILE=./vault-keys.txt
v() { docker compose exec -T -e VAULT_ADDR=http://127.0.0.1:8200 vault vault "$@"; }

docker compose ps vault --status running >/dev/null 2>&1 || {
  echo "vault is not running. Start it first:  docker compose up -d vault"; exit 1; }

# ---------------------------------------------------------------- initialise --
if v status -format=json 2>/dev/null | grep -q '"initialized": *true'; then
  echo "Vault is already initialised."
  [[ -f "$KEYS_FILE" ]] || { echo "ERROR: $KEYS_FILE is missing, so it cannot be unsealed here."; exit 1; }
  UNSEAL_KEY=$(grep '^unseal_key=' "$KEYS_FILE" | cut -d= -f2-)
  ROOT_TOKEN=$(grep '^root_token=' "$KEYS_FILE" | cut -d= -f2-)
else
  echo "Initialising Vault..."
  umask 077
  OUT=$(v operator init -key-shares=1 -key-threshold=1 -format=json)

  # Write the raw response to disk BEFORE parsing it. If parsing fails after
  # Vault has been initialised, these keys are the only ones that will ever
  # exist -- losing them makes the data unrecoverable.
  printf '%s\n' "$OUT" > ./vault-init-raw.json

  # Vault pretty-prints its JSON across several lines, so flatten it first.
  FLAT=$(printf '%s' "$OUT" | tr -d '\n\r ')
  UNSEAL_KEY=$(printf '%s' "$FLAT" | sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p')
  ROOT_TOKEN=$(printf '%s' "$FLAT" | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')

  if [[ -z "$UNSEAL_KEY" || -z "$ROOT_TOKEN" ]]; then
    echo "ERROR: could not read the keys out of Vault's response."
    echo "       Vault IS initialised. The raw response is in ./vault-init-raw.json --"
    echo "       take the unseal key and root token from there before doing anything else."
    exit 1
  fi

  printf 'unseal_key=%s\nroot_token=%s\n' "$UNSEAL_KEY" "$ROOT_TOKEN" > "$KEYS_FILE"
  rm -f ./vault-init-raw.json
  echo "Unseal key and root token written to $KEYS_FILE"
fi

# -------------------------------------------------------------------- unseal --
if v status -format=json 2>/dev/null | grep -q '"sealed": *false'; then
  echo "Vault is already unsealed."
else
  echo "Unsealing..."
  v operator unseal "$UNSEAL_KEY" >/dev/null
  echo "Unsealed."
fi

# --------------------------------------------------- KV engine + app token ---
export_token() { docker compose exec -T -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" vault vault "$@"; }

export_token secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true

cat <<'POLICY' > /tmp/authsec-policy.hcl
path "kv/*"          { capabilities = ["create","read","update","delete","list"] }
path "kv/data/*"     { capabilities = ["create","read","update","delete","list"] }
path "kv/metadata/*" { capabilities = ["read","list","delete"] }
POLICY
docker compose cp /tmp/authsec-policy.hcl vault:/tmp/authsec-policy.hcl >/dev/null
export_token policy write authsec-services /tmp/authsec-policy.hcl >/dev/null

APP_TOKEN=$(export_token token create -policy=authsec-services -ttl=8760h \
              -explicit-max-ttl=8760h -renewable=true -format=json \
            | grep -o '"client_token": *"[^"]*"' | cut -d'"' -f4)

cat <<EOF

──────────────────────────────────────────────────────────────────────
 Vault is ready.

 Put this in .env, then restart the stack:

     VAULT_TOKEN=$APP_TOKEN

     docker compose up -d

 The unseal key and root token are in $KEYS_FILE (mode 600).
 ${KEYS_FILE} is the ONLY copy -- back it up somewhere safe. Without it,
 Vault cannot be unsealed after a reboot and its data is unrecoverable.
──────────────────────────────────────────────────────────────────────
EOF
