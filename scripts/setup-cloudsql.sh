#!/usr/bin/env bash
#
# setup-cloudsql.sh - Move the Agent Substrate control-plane state store
# (ate-api-server) from the bundled in-cluster PostgreSQL StatefulSet to
# Cloud SQL for PostgreSQL, using the Cloud SQL Auth Proxy sidecar and IAM
# database authentication (no database passwords in the cluster).
#
# What it does (idempotent; safe to re-run):
#   1. Enables the Cloud SQL Admin API and creates the instance/database if missing.
#   2. Creates the Google service account (GSA) used through Workload Identity and
#      grants it Cloud SQL access AND access to the snapshot bucket (see note below).
#   3. Creates the IAM database user and runs the one-time schema GRANT.
#   4. If the target database is empty and the bundled PostgreSQL is in use,
#      copies the data (pg_dump/restore as the IAM user), verifies row-count
#      parity, and rolls back automatically on mismatch.
#   5. Points ate-api-server at Cloud SQL (Secret), configures the proxy
#      (ConfigMap), injects the proxy sidecar, and verifies the switch.
#
# Notes from validating this on a real cluster:
#   * The installer keeps the database connection string in the Secret
#     ate-api-server-secret-envvars, which overrides the ConfigMap. Editing
#     only the ConfigMap leaves ate-api-server on the in-cluster database.
#   * Annotating the ate-api-server ServiceAccount with a GSA changes the
#     identity ate-api-server uses for Cloud Storage as well, so the GSA needs
#     the same snapshot-bucket roles the ServiceAccount had.
#   * Cloud SQL IAM users start with no privileges, and PostgreSQL 15+ removed
#     CREATE on the public schema, so a one-time GRANT is required.
#   * Suspend every actor before migrating: the copy needs a quiesced control
#     plane with no actor assigned to a worker.
#
# Not covered: Cloud SQL HA failover drills and cross-region replicas. Set
# AVAILABILITY_TYPE=REGIONAL for zonal HA; replicas/DR are a separate step.
#
set -euo pipefail

# ---- Configuration (override with environment variables) --------------------
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
INSTANCE_NAME="${INSTANCE_NAME:-substrate-pg-dev}"
DB_NAME="${DB_NAME:-atepg}"
DB_VERSION="${DB_VERSION:-POSTGRES_15}"
DB_TIER="${DB_TIER:-db-custom-2-7680}"
AVAILABILITY_TYPE="${AVAILABILITY_TYPE:-ZONAL}" # REGIONAL for HA
GSA_NAME="${GSA_NAME:-ate-api-sql-sa}"
NAMESPACE="${NAMESPACE:-ate-system}"
BUCKET_NAME="${BUCKET_NAME:-ate-snapshots-${PROJECT_ID}-${REGION}}"
DB_SCHEMA="${DB_SCHEMA:-public}"
MIGRATE_DATA="${MIGRATE_DATA:-auto}" # auto | false
SOURCE_POD="${SOURCE_POD:-postgres-0}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-postgres}"
SOURCE_DB="${SOURCE_DB:-atepg}"
PROXY_IMAGE="${PROXY_IMAGE:-gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.25.2}"
PG_TOOLS_IMAGE="${PG_TOOLS_IMAGE:-postgres:18-alpine}"

GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IAM_DB_USER="${GSA_EMAIL%.gserviceaccount.com}"
KSA="ate-api-server"
DEPLOYMENT="ate-api-server"
SECRET="ate-api-server-secret-envvars"
CONFIGMAP="ate-api-server-envvars"
HELPER_POD="cloudsql-setup-helper"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDECAR_PATCH="${SCRIPT_DIR}/../manifests/ate-install/cloudsql/proxy-sidecar-patch.yaml"
BACKUP_DIR="${BACKUP_DIR:-./cloudsql-backup-$(date +%Y%m%d-%H%M%S)}"
WORKDIR="$(mktemp -d)"
PG_PASSWORD_WAS_SET=false

# ---- Helpers -----------------------------------------------------------------
log() { printf '\n--> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
kc() { kubectl -n "${NAMESPACE}" "$@"; }
psql_iam() {
  kc exec -i "${HELPER_POD}" -c tools -- psql \
    "host=127.0.0.1 port=5432 user=${IAM_DB_USER} dbname=${DB_NAME} sslmode=disable" \
    -v ON_ERROR_STOP=1 "$@"
}
psql_source() {
  kc exec -i "${SOURCE_POD}" -c "${SOURCE_CONTAINER}" -- psql -U postgres -d "${SOURCE_DB}" -v ON_ERROR_STOP=1 "$@"
}
row_counts() { # $1 = psql function; prints "table|count" sorted
  local q
  q=$("$1" -At -c "select string_agg(format('select %L, count(*) from %I.%I', tablename, schemaname, tablename), ' union all ' order by tablename) from pg_tables where schemaname='${DB_SCHEMA}'")
  [[ -z "${q}" ]] && return 0
  "$1" -At -c "${q}" | sort
}
config_fingerprint() {
  {
    kc get secret "${SECRET}" -o jsonpath='{.data}' 2>/dev/null || true
    kc get configmap "${CONFIGMAP}" -o jsonpath='{.data}' 2>/dev/null || true
    kc get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null || true
  } | sha256sum | cut -d' ' -f1
}
cleanup() {
  kc delete pod "${HELPER_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ "${PG_PASSWORD_WAS_SET}" == "true" ]]; then
    gcloud sql users set-password postgres --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" \
      --password="$(openssl rand -hex 32)" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "=========================================================="
echo "Agent Substrate: move ate-api-server state to Cloud SQL"
echo "Project:   ${PROJECT_ID}"
echo "Region:    ${REGION}"
echo "Instance:  ${INSTANCE_NAME} (${DB_VERSION}, ${AVAILABILITY_TYPE})"
echo "Database:  ${DB_NAME}"
echo "GSA:       ${GSA_EMAIL}"
echo "Bucket:    gs://${BUCKET_NAME}"
echo "=========================================================="

# ---- 0. Preflight ------------------------------------------------------------
for cmd in gcloud kubectl openssl sha256sum; do
  command -v "${cmd}" >/dev/null || die "${cmd} is required"
done
[[ -n "${PROJECT_ID}" ]] || die "PROJECT_ID is not set"
[[ -f "${SIDECAR_PATCH}" ]] || die "sidecar patch not found at ${SIDECAR_PATCH}"
kc get deployment "${DEPLOYMENT}" >/dev/null || die "deployment ${NAMESPACE}/${DEPLOYMENT} not found"
gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1 || die "bucket gs://${BUCKET_NAME} not found (set BUCKET_NAME)"

umask 077
mkdir -p "${BACKUP_DIR}"
kc get secret "${SECRET}" -o yaml >"${BACKUP_DIR}/secret.yaml" 2>/dev/null || true
kc get configmap "${CONFIGMAP}" -o yaml >"${BACKUP_DIR}/configmap.yaml" 2>/dev/null || true
kc get deployment "${DEPLOYMENT}" -o yaml >"${BACKUP_DIR}/deployment.yaml"
log "Backed up current ate-api-server config to ${BACKUP_DIR}"

# ---- 1. Cloud SQL instance and database --------------------------------------
log "Enabling sqladmin.googleapis.com"
gcloud services enable sqladmin.googleapis.com --project="${PROJECT_ID}"

if gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  flags=$(gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" \
    --format="value(settings.databaseFlags)")
  [[ "${flags}" == *"cloudsql.iam_authentication"*"on"* ]] || die "instance ${INSTANCE_NAME} exists but cloudsql.iam_authentication is not on; run: gcloud sql instances patch ${INSTANCE_NAME} --database-flags=cloudsql.iam_authentication=on (restarts the instance)"
  log "Cloud SQL instance ${INSTANCE_NAME} exists with IAM authentication on"
else
  log "Creating Cloud SQL instance ${INSTANCE_NAME} (takes a few minutes)"
  gcloud sql instances create "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --database-version="${DB_VERSION}" \
    --tier="${DB_TIER}" \
    --region="${REGION}" \
    --availability-type="${AVAILABILITY_TYPE}" \
    --database-flags=cloudsql.iam_authentication=on
fi
CONNECTION_NAME=$(gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" --format='value(connectionName)')

if ! gcloud sql databases describe "${DB_NAME}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating database ${DB_NAME}"
  gcloud sql databases create "${DB_NAME}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}"
fi

# ---- 2. Identity: GSA, Cloud SQL roles, Workload Identity, bucket roles -------
log "Configuring service account ${GSA_EMAIL}"
if ! gcloud iam service-accounts describe "${GSA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${GSA_NAME}" --project="${PROJECT_ID}" \
    --display-name="Agent Substrate ate-api-server (Cloud SQL)"
fi
for role in roles/cloudsql.client roles/cloudsql.instanceUser; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="serviceAccount:${GSA_EMAIL}" \
    --role="${role}" --condition=None --quiet --format=none
done
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" --project="${PROJECT_ID}" \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA}]" --format=none
# With the KSA annotated, ate-api-server reaches Cloud Storage as this GSA too.
for role in roles/storage.objectAdmin roles/storage.bucketViewer; do
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${GSA_EMAIL}" --role="${role}" --format=none
done

if ! gcloud sql users list --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" --format='value(name)' | grep -qx "${IAM_DB_USER}"; then
  log "Creating IAM database user ${IAM_DB_USER}"
  gcloud sql users create "${IAM_DB_USER}" --instance="${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" --type=CLOUD_IAM_SERVICE_ACCOUNT
fi
kc annotate serviceaccount "${KSA}" "iam.gke.io/gcp-service-account=${GSA_EMAIL}" --overwrite

# ---- 3. Helper pod (proxy + psql) running as the ate-api-server identity ------
log "Starting helper pod ${HELPER_POD}"
kc delete pod "${HELPER_POD}" --ignore-not-found --wait=true >/dev/null
kc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${KSA}
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
  - name: cloud-sql-proxy
    image: ${PROXY_IMAGE}
    args:
    - "--health-check"
    - "--http-address=0.0.0.0"
    - "--http-port=9801"
    - "${CONNECTION_NAME}?port=5432&auto-iam-authn=true"
    - "${CONNECTION_NAME}?port=5433"
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
    startupProbe:
      httpGet: {path: /startup, port: 9801}
      periodSeconds: 1
      failureThreshold: 60
  - name: tools
    image: ${PG_TOOLS_IMAGE}
    command: ["sleep", "3600"]
EOF
kc wait --for=condition=Ready "pod/${HELPER_POD}" --timeout=180s
for _ in $(seq 1 30); do # Workload Identity can take a moment to become usable
  psql_iam -At -c "select 1" >/dev/null 2>&1 && break
  sleep 5
done
psql_iam -At -c "select 1" >/dev/null || die "cannot log in to Cloud SQL as ${IAM_DB_USER} (check roles, IAM user, Workload Identity)"

# ---- 4. One-time schema privileges --------------------------------------------
can_ddl=$(psql_iam -At -c "select has_database_privilege(current_user, current_database(), 'CREATE') and has_schema_privilege(current_user, '${DB_SCHEMA}', 'CREATE')")
if [[ "${can_ddl}" != "t" ]]; then
  log "Granting schema privileges to ${IAM_DB_USER} (temporary postgres password, scrambled on exit)"
  openssl rand -hex 24 >"${WORKDIR}/pgpw"
  PG_PASSWORD_WAS_SET=true
  gcloud sql users set-password postgres --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" \
    --password="$(cat "${WORKDIR}/pgpw")" >/dev/null
  kc exec -i "${HELPER_POD}" -c tools -- sh -c \
    "read -r PGPASSWORD; export PGPASSWORD; psql 'host=127.0.0.1 port=5433 user=postgres dbname=${DB_NAME} sslmode=disable' -v ON_ERROR_STOP=1 \
      -c 'GRANT CREATE ON DATABASE \"${DB_NAME}\" TO \"${IAM_DB_USER}\";' \
      -c 'GRANT USAGE, CREATE ON SCHEMA \"${DB_SCHEMA}\" TO \"${IAM_DB_USER}\";'" <"${WORKDIR}/pgpw"
fi

# ---- 5. Data migration from the bundled PostgreSQL ----------------------------
target_tables=$(psql_iam -At -c "select count(*) from pg_tables where schemaname='${DB_SCHEMA}'")
source_present=false
if kc get pod "${SOURCE_POD}" >/dev/null 2>&1 && \
   kc get secret "${SECRET}" -o jsonpath='{.data.ATE_API_POSTGRES_CONNECTION_STRING}' | base64 -d | grep -q "@postgres\.${NAMESPACE}\.svc"; then
  source_present=true
fi
original_replicas=$(kc get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.replicas}')
[[ "${original_replicas}" -gt 0 ]] || original_replicas=2

if [[ "${target_tables}" -gt 0 ]]; then
  log "Target database already has ${target_tables} tables: skipping data copy (this script never overwrites)"
elif [[ "${MIGRATE_DATA}" != "false" && "${source_present}" == "true" ]]; then
  assigned=$(psql_source -At -c "select count(*) from worker_assignments")
  [[ "${assigned}" == "0" ]] || die "${assigned} actor(s) are assigned to workers. Suspend every actor first (kubectl ate get actors -a <atespace>; kubectl ate suspend actor ...)."

  log "Quiescing ate-api-server (scale to 0) for a consistent copy"
  kc scale deployment "${DEPLOYMENT}" --replicas=0
  kc wait --for=delete pod -l app="${DEPLOYMENT}" --timeout=120s || true

  row_counts psql_source >"${BACKUP_DIR}/source-rowcounts.txt"
  log "Dumping ${SOURCE_POD}/${SOURCE_DB}"
  kc exec "${SOURCE_POD}" -c "${SOURCE_CONTAINER}" -- pg_dump -U postgres -d "${SOURCE_DB}" \
    --no-owner --no-privileges --format=plain >"${BACKUP_DIR}/source-dump.sql"
  # pg_dump 17+ emits this setting; older servers reject it.
  grep -v -x "SET transaction_timeout = 0;" "${BACKUP_DIR}/source-dump.sql" >"${WORKDIR}/restore.sql"

  log "Restoring into Cloud SQL as ${IAM_DB_USER} (single transaction)"
  if ! psql_iam --single-transaction -q -f - <"${WORKDIR}/restore.sql" >/dev/null; then
    kc scale deployment "${DEPLOYMENT}" --replicas="${original_replicas}"
    die "restore failed; nothing was switched and ate-api-server was scaled back up on the in-cluster database"
  fi
  row_counts psql_iam >"${BACKUP_DIR}/target-rowcounts.txt"
  if ! diff -u "${BACKUP_DIR}/source-rowcounts.txt" "${BACKUP_DIR}/target-rowcounts.txt"; then
    kc scale deployment "${DEPLOYMENT}" --replicas="${original_replicas}"
    die "row counts differ (see diff above); nothing was switched and ate-api-server was scaled back up on the in-cluster database"
  fi
  owners=$(psql_iam -At -c "select string_agg(distinct tableowner, ',') from pg_tables where schemaname='${DB_SCHEMA}'")
  if [[ "${owners}" != "${IAM_DB_USER}" ]]; then
    kc scale deployment "${DEPLOYMENT}" --replicas="${original_replicas}"
    die "unexpected table owners (${owners}); nothing was switched and ate-api-server was scaled back up on the in-cluster database"
  fi
  log "Copied $(wc -l <"${BACKUP_DIR}/target-rowcounts.txt") tables; row counts match"
else
  log "No data to copy: ate-api-server will create the schema on first start"
fi

# ---- 6. Point ate-api-server at Cloud SQL --------------------------------------
before=$(config_fingerprint)
log "Writing the Cloud SQL connection string to Secret ${SECRET}"
dsn="user=${IAM_DB_USER} host=127.0.0.1 port=5432 dbname=${DB_NAME} sslmode=disable"
if kc get secret "${SECRET}" >/dev/null 2>&1; then
  # Patch only these keys; anything else in the Secret is left alone.
  kc patch secret "${SECRET}" --type merge -p \
    "{\"stringData\":{\"ATE_API_POSTGRES_CONNECTION_STRING\":\"${dsn}\",\"ATE_API_POSTGRES_SCHEMA\":\"${DB_SCHEMA}\"}}"
else
  kc create secret generic "${SECRET}" \
    --from-literal=ATE_API_POSTGRES_CONNECTION_STRING="${dsn}" \
    --from-literal=ATE_API_POSTGRES_SCHEMA="${DB_SCHEMA}"
fi

# The ConfigMap carries the proxy settings and nothing else (as upstream's
# installer writes it); this also drops any connection string left in it,
# which the Secret would override anyway.
log "Writing Cloud SQL Auth Proxy settings to ConfigMap ${CONFIGMAP}"
kc create configmap "${CONFIGMAP}" \
  --from-literal=ATE_API_POSTGRES_CLOUDSQL_INSTANCE="${CONNECTION_NAME}" \
  --from-literal=CSQL_PROXY_AUTO_IAM_AUTHN=true \
  --from-literal=CSQL_PROXY_PORT=5432 \
  --from-literal=CSQL_PROXY_HEALTH_CHECK=true \
  --from-literal=CSQL_PROXY_HTTP_ADDRESS=0.0.0.0 \
  --from-literal=CSQL_PROXY_HTTP_PORT=9801 \
  --dry-run=client -o yaml | kc apply -f -

if ! kc get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.template.spec.initContainers[*].name}' | grep -qw cloud-sql-proxy; then
  log "Injecting the cloud-sql-proxy sidecar"
  kc patch deployment "${DEPLOYMENT}" --patch-file "${SIDECAR_PATCH}"
fi

current_replicas=$(kc get deployment "${DEPLOYMENT}" -o jsonpath='{.spec.replicas}')
if [[ "${current_replicas}" -eq 0 ]]; then
  kc scale deployment "${DEPLOYMENT}" --replicas="${original_replicas}"
elif [[ "$(config_fingerprint)" != "${before}" ]]; then
  kc rollout restart deployment "${DEPLOYMENT}"
fi
kc rollout status deployment "${DEPLOYMENT}" --timeout=300s

# ---- 7. Verify the switch ------------------------------------------------------
log "Verifying"
failed=false
pod_ips=()
for pod in $(kc get pods -l app="${DEPLOYMENT}" -o jsonpath='{.items[*].metadata.name}'); do
  pod_ips+=("$(kc get pod "${pod}" -o jsonpath='{.status.podIP}')")
  accepted=$(kc logs "${pod}" -c cloud-sql-proxy | grep -c "Accepted connection" || true)
  ready=$(kc logs "${pod}" -c "${DEPLOYMENT}" | grep -c "PostgreSQL migrations ready" || true)
  echo "  ${pod}: proxy connections=${accepted}, store ready=${ready}"
  [[ "${accepted}" -gt 0 && "${ready}" -gt 0 ]] || failed=true
done
sessions=$(psql_iam -At -c "select count(*) from pg_stat_activity where usename = current_user and pid <> pg_backend_pid()")
echo "  Cloud SQL sessions as ${IAM_DB_USER}: ${sessions}"
[[ "${sessions}" -gt 0 ]] || failed=true
if kc get pod "${SOURCE_POD}" >/dev/null 2>&1; then
  ips=$(printf "'%s'," "${pod_ips[@]}")
  ips="${ips%,}"
  stale=$(psql_source -At -c "select count(*) from pg_stat_activity where client_addr::text in (${ips})")
  echo "  in-cluster ${SOURCE_POD} connections from ate-api-server: ${stale}"
  [[ "${stale}" == "0" ]] || failed=true
fi
[[ "${failed}" == "false" ]] || die "verification failed; to roll back: kubectl apply -f ${BACKUP_DIR}/secret.yaml && kubectl -n ${NAMESPACE} rollout restart deployment/${DEPLOYMENT}"

echo "=========================================================="
echo "ate-api-server is running on Cloud SQL (${CONNECTION_NAME}/${DB_NAME})."
echo "Backups and evidence: ${BACKUP_DIR}"
echo "Rollback: kubectl apply -f ${BACKUP_DIR}/secret.yaml && kubectl -n ${NAMESPACE} rollout restart deployment/${DEPLOYMENT}"
if kc get statefulset postgres >/dev/null 2>&1; then
  echo "The in-cluster PostgreSQL is untouched and is your rollback target. Once satisfied:"
  echo "  kubectl -n ${NAMESPACE} scale statefulset postgres --replicas=0   (keep the PVC until you are sure)"
fi
echo "=========================================================="
