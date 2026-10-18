#!/usr/bin/env bash
#
# setup-cloudsql.sh - Provision Cloud SQL for PostgreSQL, reachable only over
# Private Service Connect (PSC), as the state store for a NEW Agent Substrate
# install (Option B in the README). Run it before `ate-setup deploy ate-system`.
#
# It creates (idempotently):
#   * a PSC-only Cloud SQL instance (no public IP, no VPC peering) with IAM
#     database authentication, and the `atepg` database
#   * a PSC endpoint (internal IP + forwarding rule) in your cluster's subnet and a
#     private Cloud DNS record for the instance, which the Cloud SQL Auth Proxy needs
#   * the Google service account (GSA) ate-api-server uses through Workload
#     Identity, with Cloud SQL roles and access to the snapshot bucket
#   * the IAM database user, plus the roles and schema upstream v0.5.0 expects
#     (substrate_owner, substrate_readwrite, schema `substrate`)
#
# It then prints the environment variables to pass to ate-setup.
#
# Why the bucket roles: annotating the ate-api-server ServiceAccount with a GSA
# makes every Google API call from that pod (including the objectstore-plugin
# sidecar's snapshot access) use the GSA, so it needs the same snapshot-bucket
# roles the ServiceAccount itself has.
#
# Requires: gcloud, kubectl (current context = the target cluster; used to run a
# short-lived psql pod inside the VPC), openssl.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
NETWORK="${NETWORK:?set NETWORK to the cluster VPC name}"
SUBNET="${SUBNET:?set SUBNET to the cluster subnet name (the PSC endpoint IP comes from it)}"
BUCKET_NAME="${BUCKET_NAME:?set BUCKET_NAME to the actor snapshot bucket}"
INSTANCE_NAME="${INSTANCE_NAME:-ate-substrate-pg}"
DB_VERSION="${DB_VERSION:-POSTGRES_18}"
DB_TIER="${DB_TIER:-db-custom-2-8192}"
EDITION="${EDITION:-enterprise}"
AVAILABILITY_TYPE="${AVAILABILITY_TYPE:-ZONAL}" # REGIONAL for HA
DELETION_PROTECTION="${DELETION_PROTECTION:-true}"
GSA_NAME="${GSA_NAME:-ate-api-server}"
NAMESPACE="${NAMESPACE:-ate-system}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:18-alpine}"

DB_NAME="atepg" # the database name ate-setup's Cloud SQL DSN uses
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IAM_DB_USER="${GSA_EMAIL%.gserviceaccount.com}"
PSC_NAME="${INSTANCE_NAME}-psc"
SETUP_POD="${INSTANCE_NAME}-setup"
WORKDIR="$(mktemp -d)"
PG_PASSWORD_WAS_SET=false

log() { printf '\n--> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  kubectl -n default delete pod "${SETUP_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n default delete configmap "${SETUP_POD}" --ignore-not-found >/dev/null 2>&1 || true
  if [[ "${PG_PASSWORD_WAS_SET}" == "true" ]]; then
    gcloud sql users set-password postgres --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" \
      --password="$(openssl rand -hex 32)" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "=========================================================="
echo "Cloud SQL (PSC) for Agent Substrate"
echo "Project:   ${PROJECT_ID}    Region: ${REGION}"
echo "Network:   ${NETWORK} / ${SUBNET}"
echo "Instance:  ${INSTANCE_NAME} (${DB_VERSION}, ${EDITION}, ${AVAILABILITY_TYPE})"
echo "GSA:       ${GSA_EMAIL}"
echo "Bucket:    gs://${BUCKET_NAME}"
echo "=========================================================="

# ---- 0. Preflight ------------------------------------------------------------
for cmd in gcloud kubectl openssl; do command -v "${cmd}" >/dev/null || die "${cmd} is required"; done
[[ -n "${PROJECT_ID}" ]] || die "PROJECT_ID is not set"
gcloud compute networks describe "${NETWORK}" --project="${PROJECT_ID}" >/dev/null || die "network ${NETWORK} not found"
gcloud compute networks subnets describe "${SUBNET}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null || die "subnet ${SUBNET} not found in ${REGION}"
gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1 || die "bucket gs://${BUCKET_NAME} not found"
kubectl get --raw /readyz >/dev/null || die "kubectl cannot reach the cluster (check the current context)"

log "Enabling APIs"
gcloud services enable sqladmin.googleapis.com compute.googleapis.com dns.googleapis.com iam.googleapis.com \
  --project="${PROJECT_ID}"

# ---- 1. PSC-only instance and database ----------------------------------------
describe() { gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" --format="value($1)"; }
if gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  [[ "$(describe settings.ipConfiguration.pscConfig.pscEnabled)" == "True" ]] || die "instance ${INSTANCE_NAME} exists but is not PSC-enabled"
  [[ "$(describe settings.databaseFlags)" == *"cloudsql.iam_authentication"*"on"* ]] || die "instance ${INSTANCE_NAME} exists but cloudsql.iam_authentication is not on"
  log "Instance ${INSTANCE_NAME} exists (PSC enabled, IAM authentication on)"
else
  log "Creating PSC-only instance ${INSTANCE_NAME} (about 10 minutes)"
  protection="--deletion-protection"
  [[ "${DELETION_PROTECTION}" == "true" ]] || protection="--no-deletion-protection"
  gcloud sql instances create "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --database-version="${DB_VERSION}" \
    --edition="${EDITION}" \
    --tier="${DB_TIER}" \
    --availability-type="${AVAILABILITY_TYPE}" \
    --enable-private-service-connect \
    --allowed-psc-projects="${PROJECT_ID}" \
    --no-assign-ip \
    --database-flags=cloudsql.iam_authentication=on \
    --backup-start-time=03:00 \
    --enable-point-in-time-recovery \
    "${protection}"
fi
CONNECTION_NAME="$(describe connectionName)"
SERVICE_ATTACHMENT="$(describe pscServiceAttachmentLink)"
DNS_NAME="$(describe dnsName)"
[[ "${DNS_NAME}" == *. ]] || DNS_NAME="${DNS_NAME}."
[[ -n "${SERVICE_ATTACHMENT}" && "${DNS_NAME}" != "." ]] || die "instance has no PSC service attachment or DNS name yet"

if ! gcloud sql databases describe "${DB_NAME}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating database ${DB_NAME}"
  gcloud sql databases create "${DB_NAME}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}"
fi

# ---- 2. PSC endpoint and DNS ---------------------------------------------------
if ! gcloud compute addresses describe "${PSC_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Reserving an internal IP for the PSC endpoint in ${SUBNET}"
  gcloud compute addresses create "${PSC_NAME}" --region="${REGION}" --subnet="${SUBNET}" --project="${PROJECT_ID}"
fi
PSC_IP="$(gcloud compute addresses describe "${PSC_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(address)')"

if ! gcloud compute forwarding-rules describe "${PSC_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating the PSC endpoint ${PSC_NAME} (${PSC_IP})"
  gcloud compute forwarding-rules create "${PSC_NAME}" --region="${REGION}" --project="${PROJECT_ID}" \
    --network="${NETWORK}" --address="${PSC_NAME}" --target-service-attachment="${SERVICE_ATTACHMENT}"
fi
status=""
for _ in $(seq 1 30); do
  status="$(gcloud compute forwarding-rules describe "${PSC_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(pscConnectionStatus)')"
  [[ "${status}" == "ACCEPTED" ]] && break
  sleep 10
done
[[ "${status}" == "ACCEPTED" ]] || die "PSC endpoint status is '${status}', expected ACCEPTED"

if ! gcloud dns managed-zones describe "${PSC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating private DNS zone for ${DNS_NAME}"
  gcloud dns managed-zones create "${PSC_NAME}" --project="${PROJECT_ID}" \
    --dns-name="${DNS_NAME}" --visibility=private --networks="${NETWORK}" \
    --description="Cloud SQL PSC endpoint for ${INSTANCE_NAME}"
fi
if ! gcloud dns record-sets describe "${DNS_NAME}" --type=A --zone="${PSC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns record-sets create "${DNS_NAME}" --type=A --ttl=300 --rrdatas="${PSC_IP}" \
    --zone="${PSC_NAME}" --project="${PROJECT_ID}"
fi

# ---- 3. Identity ---------------------------------------------------------------
log "Configuring ${GSA_EMAIL}"
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
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/ate-api-server]" --format=none
for role in roles/storage.objectAdmin roles/storage.bucketViewer; do
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${GSA_EMAIL}" --role="${role}" --format=none
done
if ! gcloud sql users list --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" --format='value(name)' | grep -qx "${IAM_DB_USER}"; then
  log "Creating IAM database user ${IAM_DB_USER}"
  gcloud sql users create "${IAM_DB_USER}" --instance="${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" --type=CLOUD_IAM_SERVICE_ACCOUNT
fi

# ---- 4. One-time roles and schema (upstream v0.5.0 layout) ----------------------
log "Creating roles and the substrate schema (temporary postgres password, scrambled on exit)"
cat >"${WORKDIR}/setup.sql" <<SQL
BEGIN;
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'substrate_owner') THEN CREATE ROLE substrate_owner NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'substrate_readwrite') THEN CREATE ROLE substrate_readwrite NOLOGIN; END IF;
END \$\$;
GRANT substrate_owner TO postgres WITH SET TRUE;
GRANT substrate_owner, substrate_readwrite TO "${IAM_DB_USER}";
CREATE SCHEMA IF NOT EXISTS substrate AUTHORIZATION substrate_owner;
GRANT USAGE ON SCHEMA substrate TO substrate_readwrite;
ALTER DEFAULT PRIVILEGES FOR ROLE substrate_owner IN SCHEMA substrate
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO substrate_readwrite;
ALTER DEFAULT PRIVILEGES FOR ROLE substrate_owner IN SCHEMA substrate
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO substrate_readwrite;
ALTER DEFAULT PRIVILEGES FOR ROLE substrate_owner IN SCHEMA substrate
  GRANT EXECUTE ON ROUTINES TO substrate_readwrite;
ALTER DEFAULT PRIVILEGES FOR ROLE substrate_owner IN SCHEMA substrate
  GRANT USAGE ON TYPES TO substrate_readwrite;
COMMIT;
SQL
openssl rand -hex 24 >"${WORKDIR}/pgpw"
PG_PASSWORD_WAS_SET=true
gcloud sql users set-password postgres --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" \
  --password="$(cat "${WORKDIR}/pgpw")" >/dev/null

kubectl -n default delete pod "${SETUP_POD}" --ignore-not-found --wait=true >/dev/null
# The SQL (not secret) is mounted from a ConfigMap; only the password uses stdin.
kubectl -n default create configmap "${SETUP_POD}" --from-file=setup.sql="${WORKDIR}/setup.sql" \
  --dry-run=client -o yaml | kubectl -n default apply -f - >/dev/null
kubectl -n default apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${SETUP_POD}
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: ${PSQL_IMAGE}
    command: ["sleep", "600"]
    volumeMounts:
    - name: sql
      mountPath: /sql
  volumes:
  - name: sql
    configMap:
      name: ${SETUP_POD}
EOF
kubectl -n default wait --for=condition=Ready "pod/${SETUP_POD}" --timeout=180s >/dev/null
kubectl -n default exec "${SETUP_POD}" -- test -s /sql/setup.sql || die "setup SQL did not reach the pod"
# Connects to the PSC endpoint directly (TLS required); the password arrives on stdin.
psql_postgres() {
  kubectl -n default exec -i "${SETUP_POD}" -- sh -c \
    "read -r PGPASSWORD; export PGPASSWORD; psql 'host=${PSC_IP} port=5432 user=postgres dbname=${DB_NAME} sslmode=require' -v ON_ERROR_STOP=1 $*" \
    <"${WORKDIR}/pgpw"
}
psql_postgres -q -f /sql/setup.sql
# Verify rather than trust the exit code: both roles, the schema, and membership.
check=$(psql_postgres -At -c "\"select (select count(*) from pg_roles where rolname in ('substrate_owner','substrate_readwrite'))::text || ',' || (select count(*) from pg_namespace where nspname = 'substrate' and pg_get_userbyid(nspowner) = 'substrate_owner')::text || ',' || (select count(*) from pg_auth_members m join pg_roles r on r.oid = m.roleid join pg_roles u on u.oid = m.member where u.rolname = '${IAM_DB_USER}' and r.rolname in ('substrate_owner','substrate_readwrite'))::text\"")
[[ "${check}" == "2,1,2" ]] || die "database roles/schema not as expected (roles,schema,memberships = ${check}; want 2,1,2)"
log "Verified: roles substrate_owner/substrate_readwrite, schema substrate, and ${IAM_DB_USER} membership"
kubectl -n default delete configmap "${SETUP_POD}" --ignore-not-found >/dev/null

echo "=========================================================="
echo "Cloud SQL is ready. Install Agent Substrate (from the upstream checkout) with:"
echo
echo "  export ATE_API_POSTGRES_CLOUDSQL_INSTANCE=${CONNECTION_NAME}"
echo "  export ATE_API_POSTGRES_CLOUDSQL_GSA=${GSA_EMAIL}"
echo "  export ATE_API_POSTGRES_CLOUDSQL_IP_TYPE=psc"
echo "  ./hack/install-ate.sh --deploy-ate-system --credential-provider='{\"name\":\"k8s.io\"}'"
echo "=========================================================="
