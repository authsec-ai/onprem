#!/bin/sh
# nginx refuses to start if an ssl_certificate file is missing, so on a first
# boot we place a self-signed certificate at the path nginx expects. certbot
# replaces it with the real one a few seconds later.
set -e
LIVE=/etc/letsencrypt/live/authsec

if [ -s "$LIVE/fullchain.pem" ] && [ -s "$LIVE/privkey.pem" ]; then
  echo "certificate already present at $LIVE -- leaving it alone"
  exit 0
fi

echo "no certificate yet; generating a temporary self-signed one so nginx can start"
mkdir -p "$LIVE"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -keyout "$LIVE/privkey.pem" -out "$LIVE/fullchain.pem" \
  -subj "/CN=${APP_HOST}" \
  -addext "subjectAltName=DNS:${APP_HOST},DNS:${API_HOST},DNS:${OAUTH_HOST}" 2>/dev/null
echo "temporary certificate created for ${APP_HOST}, ${API_HOST}, ${OAUTH_HOST}"
