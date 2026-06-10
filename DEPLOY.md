# Deploying Relay to a VPS (d0187.in)

Single-host Docker deployment with nginx + Let's Encrypt HTTPS.

```
d0187.in, www.d0187.in   →  advertiser app  (frontend)  + /api /v1 /graphql → backend
admin.d0187.in           →  Ops console     (admin-ui)  + /api /v1          → backend
```

## 0. Prerequisites
- A VPS with Docker + Docker Compose v2.
- DNS **A records** pointing all three names at the VPS IP:
  `d0187.in`, `www.d0187.in`, `admin.d0187.in`.
- Ports **80** and **443** open.

## 1. Copy the project & configure
```bash
# from the project root on the VPS
cp deployment/.env.example deployment/.env      # if you didn't ship your .env
nano deployment/.env
```
Set at least these for production:
```
HTTP_PORT=80                       # ignored in prod (nginx binds 80/443 directly)
APP_BASE_URL=https://d0187.in      # used for email links
RELAY_AUTH_JWT_SECRET=<32+ random chars>
RELAY_ADMIN_EMAIL=you@d0187.in
RELAY_ADMIN_PASSWORD=<strong>
RELAY_CORS_ORIGINS=https://d0187.in,https://www.d0187.in,https://admin.d0187.in
POSTGRES_PASSWORD=<strong>   CLICKHOUSE_PASSWORD=<strong>   MINIO_ROOT_PASSWORD=<strong>
# integrations (already provided)
GOOGLE_CLIENT_ID=...  GOOGLE_CLIENT_SECRET=...  GOOGLE_REDIRECT_URI=   # leave empty → derived per-domain
SMTP_HOST=smtp.hostinger.com SMTP_PORT=465 SMTP_USER=... SMTP_PASS=... MAIL_FROM=...
FAST2SMS_API_KEY=...
```
Use strong generated values for every password and secret. Production startup rejects defaults,
short secrets, localhost CORS origins, and a non-HTTPS `APP_BASE_URL`.
`GOOGLE_REDIRECT_URI` empty is recommended: the backend derives
`https://<host>/api/auth/google/callback` from the request, so all three domains work with the
URIs you already registered in Google.

## 2. One-command TLS + bring-up
```bash
cd deployment
./init-letsencrypt.sh you@d0187.in
```
This builds images, starts a temporary self-signed cert so nginx can boot, obtains the real
Let's Encrypt cert for all three domains (webroot challenge), and reloads nginx. certbot then
auto-renews every 12h; nginx reloads every 6h.

The production override activates the `docker,prod` Spring profiles and publishes only nginx
ports 80/443. Backend, Temporal UI, and MinIO remain on the internal Docker network.

Before deploying the tenant-isolation migration, snapshot Postgres:
```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml \
  exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > relay-before-tenant-reset.sql
```
The migration removes the seeded shared demo organization and its cascading users/data. Existing
users must register again.

Remove any seeded analytics facts from ClickHouse once during this rollout:
```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml \
  exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query \
  "ALTER TABLE relay.metric_snapshot DELETE WHERE workspace_id = '"'"'22222222-2222-2222-2222-222222222222'"'"'"'
docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml \
  exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query \
  "ALTER TABLE relay.metric_daily DELETE WHERE workspace_id = '"'"'22222222-2222-2222-2222-222222222222'"'"'"'
```

Rotate the JWT, Google OAuth, database, MinIO, and admin credentials before bringing the hardened
stack up. Changing an environment variable does not automatically change an existing Postgres or
ClickHouse user's stored password; update those users with their database administration tools
before restarting with the new values.

> Test first without rate limits: `STAGING=1 ./init-letsencrypt.sh you@d0187.in`, then rerun with
> `STAGING=0` once it works.

## 3. Day-to-day
```bash
C="docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml"
$C ps
$C logs -f backend
$C up -d --build         # after pulling new code
$C down
```

## 4. Verify
- https://d0187.in → advertiser login (email / phone OTP / Google)
- https://admin.d0187.in → Ops console login (admin only)
- Google: "Continue with Google" → consents → back to the app signed in
- Sign up with email → verification email arrives → click → sign in

## Notes
- **Google authorized origins/redirects** must include (already done): `https://d0187.in`,
  `https://www.d0187.in`, `https://admin.d0187.in` and `…/api/auth/google/callback` for each.
- **Fast2SMS / Hostinger / Google** secrets live only in `deployment/.env` (git-ignored).
- TLS certs persist in `deployment/certbot/` (git-ignored) across restarts.
- Local dev is unchanged: `make dev` → http://localhost:8081 (admin at `/admin`).
