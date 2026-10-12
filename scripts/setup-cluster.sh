#!/usr/bin/env bash
#
# setup-cluster.sh - Creates the GKE cluster with all Substrate prerequisites
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VPC_NAME="${VPC_NAME:-knative-vpc}"
SUBNET_NAME="${SUBNET_NAME:-agent-substrate-subnet}"
CLUSTER_NAME="${CLUSTER_NAME:-agent-substrate-cluster}"
GKE_VERSION="${GKE_VERSION:-1.36.4-gke.2046000}"

echo "=========================================================="
echo "Creating GKE Cluster for Agent Substrate"
echo "Project:   ${PROJECT_ID}"
echo "Zone:      ${ZONE}"
echo "Cluster:   ${CLUSTER_NAME}"
echo "Version:   ${GKE_VERSION}"
echo "=========================================================="

# 1. Enable Required Google Cloud APIs
echo "--> Enabling required GCP APIs..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com

# 2. Create GKE Cluster
echo "--> Creating GKE cluster with NAP and Beta mTLS APIs..."
gcloud container clusters create "${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --cluster-version="${GKE_VERSION}" \
  --network="${VPC_NAME}" \
  --subnetwork="${SUBNET_NAME}" \
  --enable-ip-alias \
  --cluster-secondary-range-name=agent-pods \
  --services-secondary-range-name=agent-services \
  --machine-type=c3-standard-4 \
  --num-nodes=3 \
  --enable-dataplane-v2 \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --enable-kubernetes-unstable-apis=certificates.k8s.io/v1beta1/podcertificaterequests,certificates.k8s.io/v1beta1/clustertrustbundles \
  --enable-autoprovisioning \
  --min-cpu=1 \
  --max-cpu=64 \
  --min-memory=4 \
  --max-memory=256 \
  --enable-autoprovisioning-autorepair \
  --enable-autoprovisioning-autoupgrade \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring

# 3. Fetch cluster credentials
echo "--> Fetching kubeconfig credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}"

# 4. Create GCS Snapshot Storage Bucket
BUCKET_NAME="ate-snapshots-${PROJECT_ID}-${REGION}"
echo "--> Setting up Cloud Storage snapshot bucket gs://${BUCKET_NAME}..."
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi

# 5. Workload Identity Bindings
PROJECT_NUM="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
echo "--> Binding Workload Identity permissions..."
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa/atelet" \
  --role="roles/storage.objectAdmin"

gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa/ate-api-server" \
  --role="roles/storage.objectAdmin"

echo "=========================================================="
echo "Cluster creation and IAM setup complete!"
echo "You can now run: kubectl apply -f manifests/computeclass-agent-worker.yaml"
echo "=========================================================="
