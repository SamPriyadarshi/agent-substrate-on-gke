#!/usr/bin/env bash
#
# deploy-ai-mesh.sh - One-command deployment of Istio Ambient AI Mesh on GKE
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo "Deploying Istio Ambient AI Mesh for Agent Substrate"
echo "=========================================================="

echo "--> 1. Installing Istio with Ambient profile and Gateway API support..."
istioctl install --set profile=ambient --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true -y

echo "--> 2. Applying Namespaces, Service Accounts, and MCP Mock Servers..."
kubectl apply -f "${SCRIPT_DIR}/mock-tools/00-namespaces-and-identities.yaml"
kubectl apply -f "${SCRIPT_DIR}/mock-tools/01-mcp-tools-deployments.yaml"

echo "--> 3. Deploying Istio Waypoint Gateway in mcp-tools namespace..."
kubectl apply -f "${SCRIPT_DIR}/istio-ambient/02-waypoint-gateway.yaml"

echo "--> 4. Applying Strict mTLS & Fine-Grained Authorization Policies (Pillars 1 & 4)..."
kubectl apply -f "${SCRIPT_DIR}/policies/03-security-and-authz.yaml"

echo "--> 5. Applying Gateway API HTTPRoutes, Circuit Breaking & Rate Limiting (Pillars 2 & 5)..."
kubectl apply -f "${SCRIPT_DIR}/gateway-api/04-routes-and-resilience.yaml"

echo "--> 6. Applying Google Cloud Trace Distributed Observability (Pillar 3)..."
kubectl apply -f "${SCRIPT_DIR}/tracing/05-cloud-trace-telemetry.yaml"

echo "--> 7. Deploying Multi-Agent Test Workloads..."
kubectl apply -f "${SCRIPT_DIR}/mock-tools/06-agent-workloads.yaml"

echo "--> 8. Waiting for deployments to become ready..."
kubectl rollout status deployment/currency-tool -n mcp-tools --timeout=90s
kubectl rollout status deployment/database-tool -n mcp-tools --timeout=90s
kubectl rollout status deployment/search-tool -n mcp-tools --timeout=90s
kubectl rollout status deployment/agent-finance -n ate-workers --timeout=90s
kubectl rollout status deployment/agent-support -n ate-workers --timeout=90s

echo "=========================================================="
echo "Deployment successful! Run ./verify-ai-mesh.sh to run tests."
echo "=========================================================="
