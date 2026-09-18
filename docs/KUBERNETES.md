# AuthSec on your own Kubernetes cluster

Installs AuthSec on a cluster you already run — EKS, AKS, GKE, OpenShift,
Rancher, k3s, kubeadm. Nothing assumes a particular distribution.

Plan for **30–45 minutes**. Prefer one VM without Kubernetes? See
[DOCKER-COMPOSE.md](DOCKER-COMPOSE.md).

---

## 1. What gets installed

| Component | Purpose | Namespace (default) |
|---|---|---|
| PostgreSQL | application and OAuth data | `authsec-data` |
| HashiCorp Vault | secret storage | `authsec-vault` |
| Ory Hydra | OAuth2 / OIDC provider | `authsec-oauth` |
| Fluent Bit | log collection | `authsec-logging` |
| AuthSec | API, web UI, log aggregator, SPIRE, MinIO | `authsec` |

Three hostnames are published; everything else stays inside the cluster.

| Hostname | Serves |
|---|---|
| `APP_HOST` | web UI |
| `API_HOST` | AuthSec API |
| `OAUTH_HOST` | OAuth2 / OIDC issuer |

---

## 2. Prerequisites

**Cluster**

- Kubernetes **1.24+**
- A **default StorageClass** supporting `ReadWriteOnce`, or set `STORAGE_CLASS`
- **4 vCPU / 8 GiB RAM** spare minimum; 8 / 16 recommended
- **50 GiB** of persistent volume capacity

**Add-ons** — if you already run these, use yours; don't install a second.

- An **ingress controller**. Set `INGRESS_CLASS` to its class
  (`kubectl get ingressclass`).
- **cert-manager**, for automatic TLS. Without it, supply your own certificates
  as TLS secrets named `<release>-api-tls`, `<release>-app-tls`,
  `<release>-wildcard-tls` and `<release>-tls`.

**Workstation**

- `kubectl`, `helm` 3.8+, `envsubst` (in `gettext`), `openssl`, and access to the
  cluster (`kubectl get nodes` works)

**Access**

- Credentials for the AuthSec image registry
- DNS you control for the three hostnames

---

## 3. Configure

Everything comes from one file in the repository root.

```bash
./scripts/generate-secrets.sh      # creates .env, fills every secret
$EDITOR .env
```

At minimum set:

```bash
DOMAIN=example.com
APP_HOST=app.example.com
API_HOST=api.example.com
OAUTH_HOST=oauth.example.com
ACME_EMAIL=ops@example.com

REGISTRY_USER=...                  # from AuthSec
REGISTRY_PASSWORD=...

INGRESS_CLASS=nginx                # your ingress class
STORAGE_CLASS=                     # empty = cluster default
```

Worth knowing:

- **`OAUTH_ADMIN_HOST` is empty by default, and should stay that way.** Hydra's
  admin API creates and deletes OAuth clients with no authentication of its own.
  Left empty it is cluster-internal, reachable with
  `kubectl -n authsec-oauth port-forward svc/hydra-admin 4445:4445`. Set it only
  behind an authenticating proxy.
- **`ACME_SOLVER`** — `http01` (default) works with any DNS provider but cannot
  issue wildcards, and needs the hostnames resolving to your ingress first.
  `dns01` issues wildcards and works before DNS points anywhere, but needs
  `DNS_API_TOKEN`.
- **`EXTERNAL_DB_HOST`** — set it to use RDS / Cloud SQL / an existing server
  instead of deploying PostgreSQL. Create the two databases yourself first;
  see §8.
- **`POSTGRES_REPLICATION`** — `true` adds a streaming read replica. Nothing
  routes reads to it automatically, so leave it `false` unless you have a reason.

Never commit `.env`. It is gitignored, and `scripts/check-no-secrets.sh` fails if
it is present.

---

## 4. Deploy

```bash
./deploy.sh preflight     # checks the cluster and .env, changes nothing
./deploy.sh               # install or upgrade everything
```

Preflight verifies the cluster is reachable, a StorageClass exists, your ingress
class and cert-manager are present, and that no `CHANGE_ME` or `example.com`
placeholders remain.

The deploy renders your `.env` into `.generated/*.yaml` (mode 600) and applies
each chart with them layered over the chart defaults. The charts themselves are
never modified, so upgrades stay clean.

Run one component at a time if you prefer:

```bash
./deploy.sh --list
./deploy.sh --only postgres,vault --yes
./deploy.sh render        # write .generated/ and stop, to inspect the values
```

---

## 5. DNS and TLS

Find your ingress address:

```bash
kubectl -n ingress-nginx get svc
```

Create A records for `APP_HOST`, `API_HOST` and `OAUTH_HOST` pointing at it. With
`http01`, certificates are issued once those records resolve; with `dns01` they
are issued immediately.

```bash
kubectl get certificate -A                       # READY should become True
kubectl -n cert-manager logs deploy/cert-manager -f
```

`ACME_ENV=staging` issues untrusted certificates with no meaningful rate limit —
useful while DNS is still settling. Switch to `prod` and re-run
`./deploy.sh --only issuer --yes`, then delete the old secrets to force reissue:

```bash
kubectl delete secret -A -l controller.cert-manager.io/fao=true
```

---

## 6. Verify

```bash
./deploy.sh verify
./deploy.sh status
curl -sS https://$OAUTH_HOST/.well-known/openid-configuration | head -20
```

Checklist:

- [ ] every pod Running or Completed
- [ ] Vault reports `Sealed false`
- [ ] `hydra-migrate-job` Complete
- [ ] all certificates READY
- [ ] OIDC discovery returns your `OAUTH_HOST` as the issuer
- [ ] Vault unseal key backed up outside the cluster (§7)

---

## 7. Back up the Vault unseal key

It exists only inside the cluster. Losing it makes Vault's contents
unrecoverable.

```bash
kubectl -n authsec-vault get secret vault-init-keys -o yaml > vault-keys-BACKUP.yaml
```

Store it in your secrets manager and delete the local copy.

---

## 8. Using your own PostgreSQL

Set `EXTERNAL_DB_HOST` and `EXTERNAL_DB_PORT` in `.env`, then create both
databases:

```sql
CREATE ROLE authsec LOGIN PASSWORD '...';
CREATE DATABASE authsec OWNER authsec;
CREATE DATABASE hydra   OWNER authsec;
\c hydra
ALTER SCHEMA public OWNER TO authsec;
GRANT ALL ON SCHEMA public TO authsec;
```

The last two statements matter on **PostgreSQL 15+**, which revokes `CREATE` on
`public` from ordinary roles. Without them Hydra's migration fails with a
permission error. `deploy.sh` does this for you when it manages the database.

---

## 9. Day-2

**Upgrade** — set `IMAGE_TAG` in `.env`, then:

```bash
./deploy.sh --yes
```

`deploy.sh` deletes Hydra's migration job first (Jobs are immutable, so an
upgrade would otherwise fail on it).

**Back up**

```bash
kubectl -n authsec-data exec postgresql-primary-0 -c postgresql -- \
  env PGPASSWORD="$DB_PASSWORD" pg_dumpall -U postgres > authsec-$(date +%F).sql
```

Also back up the Vault key (§7) and the MinIO volume. Keep `.env` with them — the
dumps are useless without it.

**Remove**

```bash
./deploy.sh uninstall     # destroys all data, asks for confirmation
```

---

## 10. Troubleshooting

| Symptom | Cause |
|---|---|
| `ImagePullBackOff` | `REGISTRY_USER`/`REGISTRY_PASSWORD` unset or wrong, or the registry does not allow your cluster's egress IP |
| PVC stuck `Pending` | no default StorageClass, or `STORAGE_CLASS` names one that does not exist |
| `hydra-migrate-job` fails | database unreachable, or the role does not own the Hydra database (§8) |
| Hydra `CrashLoopBackOff` | normal until the migration completes |
| Certificate stuck `False` | `kubectl describe certificate`; http01 needs the hostname resolving already, dns01 needs a valid `DNS_API_TOKEN` |
| Vault pod `0/1` | Vault reports NotReady while sealed — check `kubectl -n authsec-vault logs -l app.kubernetes.io/name=vault-init` |
| App runs but login fails | a hostname in `.env` does not match the DNS record actually in use |

```bash
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> --all-containers --tail=100
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

---

## 11. Deploying without `deploy.sh`

`deploy.sh render` writes plain values files, so you can drive Helm yourself:

```bash
./deploy.sh render
helm upgrade --install postgresql charts/postgresql -n authsec-data \
  -f charts/postgresql/values.yaml -f .generated/postgresql.yaml
```

Same for `vault`, `hydra`, `fluent-bit` and `authsec`. Install in that order:
Hydra needs the database, and the application needs Vault's credential secret.

---

## Support

Include your platform, `kubectl version`, `helm list -A`, `kubectl get pods -A`,
and the failing pod's logs. Never send `.env`, `.generated/`, or Vault keys.
