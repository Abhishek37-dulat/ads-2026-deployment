#!/bin/sh
# One-time Let's Encrypt bootstrap for the Relay stack (run on the VPS, from deployment/).
#   ./init-letsencrypt.sh you@d0187.in
# Issues a single cert covering all three domains, then starts the full prod stack.
set -e

EMAIL="${1:-admin@d0187.in}"
DOMAINS="d0187.in www.d0187.in admin.d0187.in"
PRIMARY="d0187.in"
COMPOSE="docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml"
CONF="./certbot/conf"
LIVE="$CONF/live/$PRIMARY"
# staging=1 to test without hitting rate limits; set 0 for real certs
STAGING="${STAGING:-0}"

echo "▶ Building images…"
BUILDX_NO_DEFAULT_ATTESTATIONS=1 $COMPOSE build

echo "▶ Creating a temporary self-signed cert so nginx can start…"
mkdir -p "$LIVE" ./certbot/www
if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "$LIVE/privkey.pem" -out "$LIVE/fullchain.pem" -subj "/CN=$PRIMARY"
else
  docker run --rm --entrypoint openssl -v "$(pwd)/certbot/conf:/etc/letsencrypt" alpine/openssl \
    req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "/etc/letsencrypt/live/$PRIMARY/privkey.pem" \
    -out "/etc/letsencrypt/live/$PRIMARY/fullchain.pem" -subj "/CN=$PRIMARY"
fi

echo "▶ Starting stack (nginx serves the ACME challenge)…"
$COMPOSE up -d

echo "▶ Removing the dummy cert and requesting the real one…"
rm -rf "$LIVE"
DARGS=""
for d in $DOMAINS; do DARGS="$DARGS -d $d"; done
STAGEFLAG=""
[ "$STAGING" = "1" ] && STAGEFLAG="--staging"

docker run --rm \
  -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
  -v "$(pwd)/certbot/www:/var/www/certbot" \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  $STAGEFLAG --email "$EMAIL" --agree-tos --no-eff-email \
  --cert-name "$PRIMARY" $DARGS

echo "▶ Reloading nginx with the real cert…"
$COMPOSE exec nginx nginx -s reload || $COMPOSE restart nginx

echo "✅ Done. https://$PRIMARY  ·  https://admin.d0187.in"
