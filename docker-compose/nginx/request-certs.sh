#!/bin/sh
# Obtains the real Let's Encrypt certificate, once nginx is answering on :80.
# Safe to re-run: certbot exits early if the certificate is still valid.
set -e
LIVE=/etc/letsencrypt/live/authsec
STAGING=""
[ "${ACME_ENV:-prod}" = "staging" ] && STAGING="--staging"

# a self-signed placeholder has issuer == subject; a real one does not
if [ -s "$LIVE/fullchain.pem" ]; then
  iss=$(openssl x509 -in "$LIVE/fullchain.pem" -noout -issuer 2>/dev/null || echo)
  sub=$(openssl x509 -in "$LIVE/fullchain.pem" -noout -subject 2>/dev/null || echo)
  if [ "${iss#issuer=}" != "${sub#subject=}" ]; then
    echo "a CA-issued certificate is already in place; nothing to do"
    exit 0
  fi
  echo "replacing the temporary self-signed certificate"
fi

certbot certonly --webroot -w /var/www/certbot \
  --cert-name authsec \
  -d "${APP_HOST}" -d "${API_HOST}" -d "${OAUTH_HOST}" \
  --email "${ACME_EMAIL}" --agree-tos --no-eff-email \
  --non-interactive --keep-until-expiring $STAGING
