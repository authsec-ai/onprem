# AuthSec on a single VM — Docker Compose

This installs the whole AuthSec stack on one Linux machine. No Kubernetes, no
Helm — one `docker compose up`.

Plan for **20–30 minutes**.

Running Kubernetes already? Use [KUBERNETES.md](KUBERNETES.md) instead.

---

## 1. Is this the right option?

**Suits** proof-of-concept and evaluation, internal or single-team use, air-gapped
or tightly-controlled hosts, and anyone who does not want to operate Kubernetes.

**Does not suit** high availability — one host, so a reboot is downtime; nor
horizontal scaling; nor rolling upgrades. For those, use the Kubernetes guide.

All services run on one internal Docker network. Only Caddy publishes ports (80
and 443), so PostgreSQL, Vault, MinIO and Hydra's admin API are never reachable
from outside the machine.

---

## 2. Requirements

**Machine**

| | Minimum | Recommended |
|---|---|---|
| CPU | 4 vCPU | 8 vCPU |
| RAM | 8 GiB | 16 GiB |
| Disk | 50 GiB SSD | 100 GiB SSD |
| OS | any Linux with a current kernel (Ubuntu 22.04/24.04, Debian 12, RHEL 9) | |

**Software** — Docker Engine 24+ with the Compose v2 plugin:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out and back in
docker compose version            # expect v2.x
```

**Network**

- Ports **80** and **443** open to the internet (Let's Encrypt validates over 80)
- Three DNS **A records** pointing at this machine's public IP:

| Record | Serves |
|---|---|
| `app.<your-domain>` | web UI |
| `api.<your-domain>` | API |
| `oauth.<your-domain>` | OAuth2 / OIDC issuer |

Create these **before** starting, or certificate issuance fails.

- Outbound access to `docker-repo-public.authnull.com`, `quay.io`, `docker.io`
  and `hashicorp` image registries.

---

## 3. Configure

Everything comes from a single `.env` in the repository root — the same file the
Kubernetes deployment uses.

```bash
./scripts/generate-secrets.sh      # creates .env and fills every secret
$EDITOR .env                       # set DOMAIN and the three hostnames
```

Set at minimum:

```bash
DOMAIN=example.com
APP_HOST=app.example.com
API_HOST=api.example.com
OAUTH_HOST=oauth.example.com
ACME_EMAIL=ops@example.com
```

The generator replaces every `CHANGE_ME`. To do it by hand instead:

```bash
openssl rand -hex 32      # JWT / HMAC / Hydra secrets
openssl rand -base64 32   # ENCRYPTION_KEY
grep -c CHANGE_ME .env    # must print 0
```

`openssl rand -hex` produces a password with no URL-special characters, so
`DB_PASSWORD` and `DB_PASSWORD_URLENCODED` can be identical. If you set your own
password containing `@ : / ? #`, percent-encode it in the `_URLENCODED` copy
(`@`=`%40`, `:`=`%3A`, `/`=`%2F`, `#`=`%23`) — it goes into a connection URL.

Registry credentials, if yours differ from the defaults:

```bash
docker login docker-repo-public.authnull.com
```

---

## 4. Start the data layer

```bash
cd docker-compose
ln -sf ../.env .env      # so docker compose reads the root configuration
docker compose up -d postgres vault minio
docker compose ps
```

Wait for `postgres` to report `healthy` (a few seconds). It creates the
application database and Hydra's, and applies the PostgreSQL 15+ schema grants
Hydra's migration needs.

---

## 5. Initialise Vault

Vault starts **sealed** and holds no data until initialised. Once:

```bash
./vault-init.sh
```

It initialises Vault, unseals it, creates the KV store and an application token,
then prints something like:

```
VAULT_TOKEN=hvs.CAESIJ...
```

Put that line into `.env`.

> **`vault-keys.txt` is the only copy of your unseal key and root token.**
> Back it up somewhere safe — a password manager or your secrets store — and
> keep the file at mode 600. Without it Vault cannot be unsealed after a reboot,
> and its contents are unrecoverable.

---

## 6. Start everything

```bash
docker compose up -d
docker compose ps
```

First run pulls several GB of images. Order is handled for you: Hydra's
migration runs to completion before Hydra starts, and MinIO's bucket is created
before the log aggregator needs it.

Watch Caddy obtain certificates:

```bash
docker compose logs -f caddy
```

Issuance takes 10–30 seconds per hostname once DNS resolves.

---

## 7. Verify

```bash
docker compose ps            # every service Up; the *-init ones Exited (0)

curl -sS https://oauth.$(grep ^DOMAIN= .env | cut -d= -f2)/.well-known/openid-configuration | head -20
curl -sSI https://app.$(grep ^DOMAIN= .env | cut -d= -f2) | head -1     # HTTP/2 200
curl -sSI https://api.$(grep ^DOMAIN= .env | cut -d= -f2) | head -1
```

Checklist:

- [ ] all services `Up`; `hydra-migrate` and `minio-init` `Exited (0)`
- [ ] `docker compose exec vault vault status` shows `Sealed  false`
- [ ] the three URLs answer over HTTPS with a valid certificate
- [ ] OIDC discovery returns your `oauth.<domain>` issuer
- [ ] `grep -c CHANGE_ME .env` prints `0`
- [ ] `vault-keys.txt` backed up off the machine

Open `https://app.<your-domain>` to reach the UI.

---

## 8. Operating it

**Logs**

```bash
docker compose logs -f              # everything
docker compose logs -f authsec      # one service
```

**Restart / stop**

```bash
docker compose restart authsec
docker compose down                 # stop, keep data
docker compose down -v              # stop and DESTROY all volumes
```

**After a host reboot**

Containers restart automatically (`restart: unless-stopped`), but **Vault comes
back sealed** and the API will not work until it is unsealed:

```bash
./vault-init.sh     # detects an initialised Vault and only unseals it
```

To avoid that manual step, run it from a systemd unit on boot.

**Upgrade**

```bash
docker compose pull
docker compose up -d
```

Back up first. Set `IMAGE_TAG` in `.env` to pin a specific version instead of
tracking `production`.

**Back up** — everything that matters is the database, Vault's data and MinIO:

```bash
# database
docker compose exec -T postgres pg_dumpall -U "$(grep ^DB_USER= .env | cut -d= -f2)" \
  > authsec-$(date +%F).sql

# vault + minio volumes
docker run --rm -v authsec_vault-data:/v -v "$PWD:/b" alpine \
  tar czf /b/vault-$(date +%F).tar.gz -C /v .
docker run --rm -v authsec_minio-data:/v -v "$PWD:/b" alpine \
  tar czf /b/minio-$(date +%F).tar.gz -C /v .
```

Keep `.env` and `vault-keys.txt` with the backups — the dumps are useless
without them.

**Restore**

```bash
docker compose down
docker compose up -d postgres
cat authsec-YYYY-MM-DD.sql | docker compose exec -T postgres psql -U "$DB_USER"
docker compose up -d
```

---

## 9. Hardening

The defaults are safe to expose, but for production also:

- **Firewall everything except 80, 443 and SSH.** No other port needs to be
  reachable; Docker publishes nothing else.
  ```bash
  sudo ufw allow 22,80,443/tcp && sudo ufw enable
  ```
- **Keep Hydra's admin API internal.** It creates and deletes OAuth clients with
  no authentication of its own. The supplied `Caddyfile` deliberately does not
  route to it. Use:
  ```bash
  docker compose exec hydra hydra list clients --endpoint http://127.0.0.1:4445
  ```
- **Protect `.env` and `vault-keys.txt`** — mode 600, never committed to git.
- **Rotate secrets on a schedule.** Note that changing `HYDRA_SECRETS_SYSTEM`
  invalidates every issued token, and `ENCRYPTION_KEY` cannot be changed without
  re-encrypting existing data.
- **Patch the host**, and `docker compose pull` regularly.
- **Test a restore.** An untested backup is not a backup.

---

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Caddy cannot get a certificate | DNS does not resolve to this host yet, or port 80 is blocked. Check with `dig +short app.<domain>` and `docker compose logs caddy`. |
| `hydra-migrate` exits non-zero | Database not reachable or the password disagrees. `docker compose logs hydra-migrate`; confirm `DB_PASSWORD` and `DB_PASSWORD_URLENCODED` match. |
| API returns 500 on anything using secrets | `VAULT_TOKEN` empty or expired, or Vault sealed. `docker compose exec vault vault status`. |
| Vault sealed after reboot | Expected. Run `./vault-init.sh`. |
| `pull access denied` | `docker login docker-repo-public.authnull.com`, or the registry does not allow this host's IP. |
| Postgres healthy but apps cannot connect | The init scripts run **only** on an empty volume. If you changed `DB_USER`/`DB_PASSWORD` after the first start: `docker compose down -v` (destroys data) and start again. |
| `port is already allocated` | Something else holds 80/443 — often a host nginx or Apache. `sudo ss -ltnp \| grep -E ':(80\|443)'`. |
| Everything slow, containers OOM-killed | Under 8 GiB RAM. Check `docker stats`. |

Collect diagnostics:

```bash
docker compose ps
docker compose logs --tail=200 > authsec-logs.txt
```

Send `authsec-logs.txt` with any support request — but scrub it first; logs may
contain hostnames and tokens. Never send `.env` or `vault-keys.txt`.

---

## What runs where

| Service | Port (internal) | Published | Purpose |
|---|---|---|---|
| caddy | 80, 443 | **yes** | TLS termination, routing |
| ui | 3000 | no | web interface |
| authsec | 4331 | no | API |
| hydra | 4444 public, 4445 admin | no | OAuth2 / OIDC |
| log-aggregator | 7466 | no | log ingestion |
| spire-headless | 7475 | no | workload identity |
| postgres | 5432 | no | database |
| vault | 8200 | no | secrets |
| minio | 9000, 9001 | no | log object storage |
| fluent-bit | 2020, 8888 | no | log collection |
