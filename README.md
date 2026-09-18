# AuthSec — on-premise deployment

Run AuthSec on your own infrastructure. Two supported paths, one configuration
file.

```bash
git clone <this-repo> && cd onprem
./scripts/generate-secrets.sh      # creates .env with fresh secrets
$EDITOR .env                       # set DOMAIN and your hostnames
```

Then pick one:

```bash
./deploy.sh                        # Kubernetes  → docs/KUBERNETES.md
cd docker-compose && docker compose up -d    # one VM → docs/DOCKER-COMPOSE.md
```

## Which path?

| | [Kubernetes](docs/KUBERNETES.md) | [Docker Compose](docs/DOCKER-COMPOSE.md) |
|---|---|---|
| **Use when** | you already run a cluster | you want a single VM |
| Setup | 30–45 min | 20–30 min |
| High availability | yes, if your cluster is | no — single host |
| Horizontal scaling | yes | no |
| Rolling upgrades | yes | brief restart |
| Needs | K8s 1.24+, ingress controller, StorageClass | Docker 24+, ports 80/443 |
| TLS | cert-manager | automatic, via Caddy |

Both deploy the same product: the AuthSec API and web UI, Ory Hydra for
OAuth2/OIDC, PostgreSQL, HashiCorp Vault, a log pipeline and object storage.

## Configuration

`.env` in this directory is the **only** file you edit. It holds your domain,
hostnames, credentials and placement. Nothing else needs changing.

For Kubernetes, `./deploy.sh` renders it into `.generated/*.yaml` and layers
those over the chart defaults — the charts in `charts/` are never modified, so
upgrades stay clean. Inspect what would be applied with `./deploy.sh render`.

The charts ship with **no credentials and no hostnames**. Anything that looks
like a secret in them is the literal string `CHANGE_ME`.

## Layout

```
.env.example            every setting, documented
deploy.sh               Kubernetes install / upgrade / verify / uninstall
charts/                 Helm charts: postgresql, vault, hydra, fluent-bit, authsec
values/                 templates rendered from .env into .generated/
docker-compose/         single-VM stack (reads the same .env)
docs/                   the two deployment guides
scripts/
  generate-secrets.sh   fills every CHANGE_ME in .env
  check-no-secrets.sh   pre-publish safety check
```

## Before you go live

- Replace every `CHANGE_ME` — `./scripts/generate-secrets.sh` does it, and
  `./deploy.sh preflight` refuses to run while any remain
- Keep Hydra's admin API internal (`OAUTH_ADMIN_HOST` empty) unless it is behind
  an authenticating proxy
- Back up Vault's unseal key — it exists only inside your deployment
- `chmod 600 .env`, and never commit it

## Support

Include your platform and versions, and the failing component's logs. Never send
`.env`, `.generated/`, `vault-keys.txt`, or Vault keys.
