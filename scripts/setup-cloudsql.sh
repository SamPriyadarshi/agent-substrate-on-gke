#!/usr/bin/env bash
#
# setup-cloudsql.sh - Automates provisioning Cloud SQL for PostgreSQL and
# migrating Agent Substrate ate-api-server to external managed state.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
INSTANCE_NAME="${INSTANCE_NAME:-substrate-pg-dev}"
DB_NAME="${DB_NAME:-substrate}"
GSA_NAME="ate-api-sql-sa"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
IAM_DB_USER="${GSA_NAME}@${PROJECT_ID}.iam"

echo "=========================================================="
echo "Configuring Cloud SQL for PostgreSQL for Agent Substrate"
echo "Project:   ${PROJECT_ID}"
echo "Region:    ${REGION}"
echo "Instance:  ${INSTANCE_NAME}"
echo "=========================================================="

# 1. Enable Cloud SQL Admin API
echo "--> Enabling sqladmin.googleapis.com..."
gcloud services enable sqladmin.googleapis.com --project="${PROJECT_ID}"

# 2. Check / Create Cloud SQL Instance
if ! gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "--> Provisioning Cloud SQL instance ${INSTANCE_NAME}..."
  gcloud sql instances create "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --database-version=POSTGRES_15 \
    --tier=db-custom-2-7680 \
    --region="${REGION}" \
    --database-flags=cloudsql.iam_authentication=on
else
  echo "--> Cloud SQL instance ${INSTANCE_NAME} already exists."
fi

# 3. Create Database
if ! gcloud sql databases describe "${DB_NAME}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "--> Creating database ${DB_NAME}..."
  gcloud sql databases create "${DB_NAME}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}"
fi

# 4. Service Account & IAM Bindings
echo "--> Configuring Google Service Account & Workload Identity..."
if ! gcloud iam service-accounts describe "${GSA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="Agent Substrate ate-api-server Cloud SQL SA"
fi

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/cloudsql.client" \
  --condition=None --quiet

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/cloudsql.instanceUser" \
  --condition=None --quiet

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[ate-system/ate-api-server]" \
  --condition=None --quiet

# 5. Create Cloud SQL IAM User
if ! gcloud sql users list --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" | grep -q "${IAM_DB_USER}"; then
  echo "--> Creating Cloud SQL IAM database user..."
  gcloud sql users create "${IAM_DB_USER}" \
    --instance="${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --type=CLOUD_IAM_SERVICE_ACCOUNT
fi

# 6. Annotate Kubernetes ServiceAccount
echo "--> Annotating K8s Service Account ate-system/ate-api-server..."
kubectl annotate serviceaccount ate-api-server -n ate-system \
  iam.gke.io/gcp-service-account="${GSA_EMAIL}" \
  --overwrite

# 7. Update ConfigMap
CONNECTION_NAME=$(gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" --format='value(connectionName)')
echo "--> Updating ate-api-server-envvars ConfigMap with connection name: ${CONNECTION_NAME}..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ate-api-server-envvars
  namespace: ate-system
data:
  ATE_API_POSTGRES_CLOUDSQL_INSTANCE: "${CONNECTION_NAME}"
  CSQL_PROXY_AUTO_IAM_AUTHN: "true"
  CSQL_PROXY_PORT: "5432"
  CSQL_PROXY_HEALTH_CHECK: "true"
  CSQL_PROXY_HTTP_ADDRESS: "0.0.0.0"
  CSQL_PROXY_HTTP_PORT: "9801"
  ATE_API_POSTGRES_CONNECTION_STRING: "host=127.0.0.1 port=5432 user=${IAM_DB_USER} dbname=${DB_NAME} sslmode=disable"
  ATE_API_POSTGRES_SCHEMA: "public"
EOF

# 8. Apply Sidecar Patch
echo "--> Patching ate-api-server deployment with cloud-sql-proxy sidecar..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl patch deployment ate-api-server -n ate-system \
  --patch-file "${SCRIPT_DIR}/../manifests/ate-install/cloudsql/proxy-sidecar-patch.yaml"

echo "--> Waiting for ate-api-server deployment rollout..."
kubectl rollout status deployment ate-api-server -n ate-system --timeout=180s

echo "=========================================================="
echo "Successfully migrated Agent Substrate to Cloud SQL!"
echo "ate-api-server is healthy and using Cloud SQL for PostgreSQL."
echo "=========================================================="
