#!/usr/bin/env bash
# =============================================================================
#  AuthSec — Kubernetes deployment
# =============================================================================
#  Everything is driven by the .env file next to this script.
#
#      cp .env.example .env
#      ./scripts/generate-secrets.sh
#      $EDITOR .env                  # set DOMAIN and the hostnames
#      ./deploy.sh
#
#  Commands:
#      ./deploy.sh                   install or upgrade everything
#      ./deploy.sh preflight         check the cluster and .env, change nothing
#      ./deploy.sh render            write the generated values files and stop
#      ./deploy.sh verify            health-check what is deployed
#      ./deploy.sh status            pods, ingresses, certificates
#      ./deploy.sh uninstall         remove everything, including data
#
#  Flags:
#      --only a,b     run just these components   (see --list)
#      --skip a,b     run everything except these
#      --yes          do not prompt
#      --list         show component names
# =============================================================================
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
GEN_DIR="${GEN_DIR:-$HERE/.generated}"

COMPONENTS=(namespaces registry issuer postgres vault hydra fluent-bit authsec)
ONLY=""; SKIP=""; ASSUME_YES=false; CMD=install

if [[ -t 1 ]]; then
  R=$'\033[0m'; RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[1;34m'; DIM=$'\033[2m'; BLD=$'\033[1m'
else R=""; RED=""; GRN=""; YEL=""; BLU=""; DIM=""; BLD=""; fi
log()  { printf '%s %s\n' "${DIM}$(date +%H:%M:%S)${R}" "$*"; }
info() { printf '%s %s%s%s\n' "${DIM}$(date +%H:%M:%S)${R}" "$BLU" "$*" "$R"; }
ok()   { printf '%s %s✔ %s%s\n' "${DIM}$(date +%H:%M:%S)${R}" "$GRN" "$*" "$R"; }
warn() { printf '%s %s! %s%s\n' "${DIM}$(date +%H:%M:%S)${R}" "$YEL" "$*" "$R"; }
err()  { printf '%s %s✖ %s%s\n' "${DIM}$(date +%H:%M:%S)${R}" "$RED" "$*" "$R" >&2; }
die()  { err "$*"; exit 1; }
banner(){ printf '\n%s%s%s\n%s  %s%s\n%s%s%s\n\n' "$BLD$BLU" "══════════════════════════════════════════════════════════════" "$R" "$BLD$BLU" "$*" "$R" "$BLD$BLU" "══════════════════════════════════════════════════════════════" "$R"; }

trap 'err "failed at line $LINENO"; echo; echo "  Fix the cause and re-run -- every step is idempotent."; exit 1' ERR

while (( $# )); do
  case "$1" in
    --only)  ONLY="$2"; shift ;;     --only=*)  ONLY="${1#*=}" ;;
    --skip)  SKIP="$2"; shift ;;     --skip=*)  SKIP="${1#*=}" ;;
    --yes|-y) ASSUME_YES=true ;;
    --list)  printf '%s\n' "${COMPONENTS[@]}"; exit 0 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  CMD="$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- load .env --
[[ -f "$ENV_FILE" ]] || die ".env not found. Start with:  cp .env.example .env && ./scripts/generate-secrets.sh"
set -a
# shellcheck disable=SC1090  # path comes from ENV_FILE at runtime
. "$ENV_FILE"
set +a

: "${DOMAIN:?DOMAIN must be set in .env}"
APP_HOST="${APP_HOST:-app.$DOMAIN}"
API_HOST="${API_HOST:-api.$DOMAIN}"
OAUTH_HOST="${OAUTH_HOST:-oauth.$DOMAIN}"
OAUTH_ADMIN_HOST="${OAUTH_ADMIN_HOST:-}"
CLUSTER_ISSUER="letsencrypt-prod"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
STORAGE_CLASS_OR_NULL="${STORAGE_CLASS:-null}"
IMAGE_PULL_SECRET=""
[[ -n "${REGISTRY_USER:-}" ]] && IMAGE_PULL_SECRET="authsec-registry"
PG_ARCHITECTURE=$([[ "${POSTGRES_REPLICATION:-false}" == "true" ]] && echo replication || echo standalone)
PROMETHEUS_OPERATOR="${PROMETHEUS_OPERATOR:-false}"

# where the database lives
if [[ -n "${EXTERNAL_DB_HOST:-}" ]]; then
  DB_HOST="$EXTERNAL_DB_HOST"; DB_PORT="${EXTERNAL_DB_PORT:-5432}"
else
  DB_HOST="${REL_POSTGRES}-primary.${NS_DATABASE}.svc.cluster.local"; DB_PORT=5432
fi

HYDRA_DSN="postgres://${DB_USER}:${DB_PASSWORD_URLENCODED}@${DB_HOST}:${DB_PORT}/${HYDRA_DB_NAME}?sslmode=disable"
b64() { printf '%s' "$1" | base64 -w0; }
HYDRA_DSN_B64=$(b64 "$HYDRA_DSN")
HYDRA_SECRETS_SYSTEM_B64=$(b64 "$HYDRA_SECRETS_SYSTEM")
HYDRA_SECRETS_COOKIE_B64=$(b64 "$HYDRA_SECRETS_COOKIE")
HYDRA_PAIRWISE_SALT_B64=$(b64 "$HYDRA_PAIRWISE_SALT")
export APP_HOST API_HOST OAUTH_HOST OAUTH_ADMIN_HOST CLUSTER_ISSUER INGRESS_CLASS \
       STORAGE_CLASS STORAGE_CLASS_OR_NULL IMAGE_PULL_SECRET PG_ARCHITECTURE \
       DB_HOST DB_PORT HYDRA_DSN HYDRA_DSN_B64 HYDRA_SECRETS_SYSTEM_B64 \
       HYDRA_SECRETS_COOKIE_B64 HYDRA_PAIRWISE_SALT_B64 PROMETHEUS_OPERATOR

[[ -n "${KUBECONFIG_PATH:-}" ]] && export KUBECONFIG="$KUBECONFIG_PATH"
kc() { kubectl "$@"; }

selected() {
  local c=$1
  [[ -n "$ONLY" && ",$ONLY," != *",$c,"* ]] && return 1
  [[ -n "$SKIP" && ",$SKIP," == *",$c,"* ]] && return 1
  return 0
}

# --------------------------------------------------------------- rendering --
render() {
  mkdir -p "$GEN_DIR"; chmod 700 "$GEN_DIR"
  local t out
  for t in "$HERE"/values/*.yaml.tpl; do
    out="$GEN_DIR/$(basename "${t%.tpl}")"
    # only substitute names we exported; leave anything else untouched
    envsubst < "$t" > "$out"
    chmod 600 "$out"
  done
  ok "values rendered into ${GEN_DIR#"$HERE"/}/ (mode 600)"
}

# -------------------------------------------------------------- preflight ---
preflight() {
  banner "Preflight"
  local bad=0
  for c in kubectl helm envsubst base64; do
    command -v "$c" >/dev/null || { err "missing required tool: $c"; bad=1; }
  done
  (( bad )) && die "install the missing tools and re-run"
  ok "tooling present"

  kc get nodes >/dev/null 2>&1 || die "cannot reach the cluster (KUBECONFIG_PATH=${KUBECONFIG_PATH:-<current context>})"
  ok "cluster reachable: $(kc get nodes --no-headers | grep -c ' Ready') node(s) Ready"

  local sc; sc=$(kc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
  if [[ -n "$STORAGE_CLASS" ]]; then
    kc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 && ok "StorageClass $STORAGE_CLASS exists" \
      || { err "StorageClass '$STORAGE_CLASS' not found"; bad=1; }
  elif [[ -n "$sc" ]]; then ok "default StorageClass: $sc"
  else err "no default StorageClass and STORAGE_CLASS is empty -- PVCs would stay Pending"; bad=1; fi

  kc get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1 && ok "IngressClass $INGRESS_CLASS exists" \
    || warn "IngressClass '$INGRESS_CLASS' not found -- install an ingress controller, or set INGRESS_CLASS"

  kc get crd certificates.cert-manager.io >/dev/null 2>&1 && ok "cert-manager CRDs present" \
    || warn "cert-manager not installed -- certificates will not be issued automatically"

  # unreplaced placeholders
  local left; left=$(grep -c 'CHANGE_ME' "$ENV_FILE" || true)
  if (( left )); then
    err "$left value(s) in .env are still CHANGE_ME -- run ./scripts/generate-secrets.sh"; bad=1
  else ok "no CHANGE_ME placeholders left in .env"; fi

  [[ "$DOMAIN" == "example.com" ]] && { err "DOMAIN is still example.com"; bad=1; } || ok "domain: $DOMAIN"
  for h in "$APP_HOST" "$API_HOST" "$OAUTH_HOST"; do
    [[ "$h" == *example.com ]] && { err "hostname still points at example.com: $h"; bad=1; }
  done

  (( bad )) && die "preflight failed"
  ok "preflight passed"
}

# ------------------------------------------------------------- components ---
ensure_ns() { kc get ns "$1" >/dev/null 2>&1 || { kc create ns "$1" >/dev/null; ok "namespace/$1 created"; }; }

do_namespaces() {
  info "namespaces"
  for n in "$NS_DATABASE" "$NS_VAULT" "$NS_HYDRA" "$NS_LOGGING" "$NS_APP"; do ensure_ns "$n"; done
}

do_registry() {
  [[ -z "${REGISTRY_USER:-}" ]] && { log "${DIM}no REGISTRY_USER set -- assuming anonymous pulls${R}"; return 0; }
  info "image pull secret"
  kc -n "$NS_APP" create secret docker-registry authsec-registry \
    --docker-server="$REGISTRY" --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASSWORD" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ok "secret/authsec-registry in $NS_APP"
}

do_issuer() {
  kc get crd clusterissuers.cert-manager.io >/dev/null 2>&1 || { warn "cert-manager not installed; skipping ClusterIssuer"; return 0; }
  info "ClusterIssuer $CLUSTER_ISSUER (${ACME_ENV})"
  local server=https://acme-v02.api.letsencrypt.org/directory
  [[ "${ACME_ENV:-prod}" == "staging" ]] && server=https://acme-staging-v02.api.letsencrypt.org/directory

  local solver
  if [[ "${ACME_SOLVER:-http01}" == "dns01" ]]; then
    [[ -n "${DNS_API_TOKEN:-}" ]] || die "ACME_SOLVER=dns01 but DNS_API_TOKEN is empty"
    kc -n "$NS_CERTMGR" create secret generic authsec-dns-token \
      --from-literal=api-token="$DNS_API_TOKEN" --dry-run=client -o yaml | kc apply -f - >/dev/null
    solver="      - dns01:
          cloudflare:
            apiTokenSecretRef: { name: authsec-dns-token, key: api-token }"
  else
    solver="      - http01:
          ingress:
            class: $INGRESS_CLASS"
  fi

  kc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $CLUSTER_ISSUER
spec:
  acme:
    server: $server
    email: $ACME_EMAIL
    privateKeySecretRef:
      name: $CLUSTER_ISSUER
    solvers:
$solver
EOF
  ok "ClusterIssuer applied (${ACME_SOLVER:-http01} solver)"
}

helm_install() {           # helm_install <release> <ns> <chart-dir> <generated-values> [extra…]
  local rel=$1 ns=$2 chart=$3 vals=$4; shift 4
  local status
  status=$(helm -n "$ns" list -a -f "^${rel}\$" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [[ "$status" == "pending-install" || ( "$status" == "failed" && -z "$(helm -n "$ns" history "$rel" 2>/dev/null | grep deployed)" ) ]]; then
    warn "release $rel is in '$status' and cannot be upgraded -- removing it first"
    helm -n "$ns" uninstall "$rel" --wait --timeout 5m >/dev/null 2>&1 || true
  fi
  helm upgrade --install "$rel" "$chart" -n "$ns" \
    -f "$chart/values.yaml" -f "$vals" --timeout 10m "$@"
}

do_postgres() {
  [[ -n "${EXTERNAL_DB_HOST:-}" ]] && { log "${DIM}EXTERNAL_DB_HOST set -- not deploying PostgreSQL${R}"; return 0; }
  info "PostgreSQL"
  helm_install "$REL_POSTGRES" "$NS_DATABASE" "$HERE/charts/postgresql" "$GEN_DIR/postgresql.yaml"
  kc -n "$NS_DATABASE" rollout status "statefulset/${REL_POSTGRES}-primary" --timeout=10m
  # Hydra's database must be owned by the application role (PostgreSQL 15+)
  info "granting ${DB_USER} ownership of ${HYDRA_DB_NAME}"
  kc -n "$NS_DATABASE" exec -i "${REL_POSTGRES}-primary-0" -c postgresql -- \
    env PGPASSWORD="$DB_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -h 127.0.0.1 -d "$HYDRA_DB_NAME" >/dev/null <<SQL
ALTER DATABASE "$HYDRA_DB_NAME" OWNER TO "$DB_USER";
ALTER SCHEMA public OWNER TO "$DB_USER";
GRANT ALL ON SCHEMA public TO "$DB_USER";
SQL
  ok "database ready"
}

do_vault() {
  info "Vault"
  helm_install "$REL_VAULT" "$NS_VAULT" "$HERE/charts/vault" "$GEN_DIR/vault.yaml" || {
    warn "Vault did not finish cleanly; the rest of the install continues"; return 0; }
  local _i
  local _i
  for _i in $(seq 1 36); do
    kc -n "$NS_VAULT" exec "${REL_VAULT}-0" -c vault -- vault status -format=json 2>/dev/null \
      | grep -q '"sealed": *false' && { ok "Vault initialised and unsealed"; return 0; }
    sleep 5
  done
  warn "Vault is still sealed -- check: kubectl -n $NS_VAULT logs -l app.kubernetes.io/name=vault-init"
}

do_hydra() {
  info "Ory Hydra"
  kc -n "$NS_HYDRA" delete job hydra-migrate-job --ignore-not-found >/dev/null 2>&1 || true
  helm_install "$REL_HYDRA" "$NS_HYDRA" "$HERE/charts/hydra" "$GEN_DIR/hydra.yaml"
  if kc -n "$NS_HYDRA" wait --for=condition=complete job/hydra-migrate-job --timeout=300s >/dev/null 2>&1; then
    ok "database migration completed"
  else
    kc -n "$NS_HYDRA" logs job/hydra-migrate-job --tail=40 2>/dev/null || true
    die "hydra migration failed -- check DB_USER/DB_PASSWORD and that ${HYDRA_DB_NAME} exists"
  fi
  kc -n "$NS_HYDRA" rollout status deployment/hydra --timeout=5m
}

do_fluentbit() {
  info "Fluent Bit"
  helm_install "$REL_FLUENTBIT" "$NS_LOGGING" "$HERE/charts/fluent-bit" "$GEN_DIR/fluent-bit.yaml" || {
    warn "Fluent Bit did not become ready; nothing else depends on it"; return 0; }
}

do_authsec() {
  info "AuthSec"
  helm_install "$REL_APP" "$NS_APP" "$HERE/charts/authsec" "$GEN_DIR/authsec.yaml"
  local bad
  bad=$(kc -n "$NS_APP" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' 2>/dev/null \
        | grep -E 'ImagePullBackOff|ErrImagePull' || true)
  if [[ -n "$bad" ]]; then
    err "images cannot be pulled:"; printf '%s\n' "$bad"
    warn "set REGISTRY_USER/REGISTRY_PASSWORD in .env, or allow this cluster to reach $REGISTRY"
  fi
}

# ------------------------------------------------------------------ verify --
verify() {
  banner "Verify"
  local f=0
  chk() { local l=$1; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else err "$l"; f=$((f+1)); fi; }
  chk "cluster reachable"        kc get nodes
  [[ -z "${EXTERNAL_DB_HOST:-}" ]] && chk "postgres accepting connections" \
      kc -n "$NS_DATABASE" exec "${REL_POSTGRES}-primary-0" -c postgresql -- pg_isready -U postgres -h 127.0.0.1
  chk "vault unsealed"           bash -c "kubectl -n $NS_VAULT exec ${REL_VAULT}-0 -c vault -- vault status -format=json | grep -q '\"sealed\": *false'"
  chk "hydra available"          bash -c "[[ \$(kubectl -n $NS_HYDRA get deploy hydra -o jsonpath='{.status.readyReplicas}') -ge 1 ]]"
  chk "authsec pods available"   bash -c "[[ -z \$(kubectl -n $NS_APP get deploy --no-headers | awk '{split(\$2,a,\"/\"); if (a[1]!=a[2]) print}') ]]"
  echo; info "certificates:"; kc get certificate -A 2>/dev/null || true
  echo; info "not Running/Completed:"
  kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' || echo "  (none)"
  echo
  (( f )) && { warn "$f check(s) failed"; return 1; }
  ok "all checks passed"
}

status() {
  banner "Status"
  for n in "$NS_APP" "$NS_HYDRA" "$NS_VAULT" "$NS_DATABASE" "$NS_LOGGING"; do
    echo "── $n"; kc -n "$n" get pods 2>/dev/null || true; echo
  done
  info "ingresses:";    kc get ingress -A 2>/dev/null || true
  info "certificates:"; kc get certificate -A 2>/dev/null || true
}

uninstall() {
  banner "Uninstall"
  cat <<EOF
${RED}${BLD}This removes AuthSec and DESTROYS its data${R} — databases, Vault (including its
unseal key) and the log archive. It cannot be undone.
EOF
  if ! $ASSUME_YES; then
    read -r -p "Type 'destroy' to confirm: " a; [[ "$a" == "destroy" ]] || die "aborted"
  fi
  helm uninstall "$REL_APP" -n "$NS_APP" 2>/dev/null || true
  helm uninstall "$REL_HYDRA" -n "$NS_HYDRA" 2>/dev/null || true
  helm uninstall "$REL_FLUENTBIT" -n "$NS_LOGGING" 2>/dev/null || true
  helm uninstall "$REL_VAULT" -n "$NS_VAULT" 2>/dev/null || true
  helm uninstall "$REL_POSTGRES" -n "$NS_DATABASE" 2>/dev/null || true
  kc delete ns "$NS_APP" "$NS_HYDRA" "$NS_LOGGING" "$NS_VAULT" "$NS_DATABASE" --ignore-not-found 2>/dev/null || true
  ok "removed"
}

# -------------------------------------------------------------------- main --
case "$CMD" in
  render)    render ;;
  preflight) render; preflight ;;
  verify)    verify ;;
  status)    status ;;
  uninstall) uninstall ;;
  install)
    banner "AuthSec deployment"
    cat <<EOF
  Domain        : $DOMAIN
  App / API     : https://$APP_HOST  |  https://$API_HOST
  OAuth issuer  : https://$OAUTH_HOST
  Certificates  : Let's Encrypt ${ACME_ENV:-prod} via ${ACME_SOLVER:-http01}
  Database      : $DB_HOST
  Namespaces    : $NS_APP, $NS_HYDRA, $NS_VAULT, $NS_DATABASE, $NS_LOGGING
  Components    : ${ONLY:-all}

EOF
    $ASSUME_YES || { read -r -p "Proceed? [y/N] " a; [[ "$a" =~ ^[Yy] ]] || die "aborted"; }
    render; preflight
    selected namespaces  && do_namespaces
    selected registry    && do_registry
    selected issuer      && do_issuer
    selected postgres    && do_postgres
    selected vault       && do_vault
    selected hydra       && do_hydra
    selected fluent-bit  && do_fluentbit
    selected authsec     && do_authsec
    echo; verify || true
    banner "Done"
    cat <<EOF
  https://$APP_HOST     web UI
  https://$API_HOST     API
  https://$OAUTH_HOST/.well-known/openid-configuration

  Point DNS for those names at your ingress:
    kubectl -n $NS_INGRESS get svc

  Back up Vault's unseal key — it exists only in the cluster:
    kubectl -n $NS_VAULT get secret ${REL_VAULT}-init-keys -o yaml > vault-keys-BACKUP.yaml
EOF
    ;;
  *) die "unknown command '$CMD' (try --help)" ;;
esac
