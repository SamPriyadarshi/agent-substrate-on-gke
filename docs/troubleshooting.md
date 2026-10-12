# Troubleshooting & Common Pitfalls: Agent Substrate on GKE

This guide captures real-world edge cases, organizational policy roadblocks, and debugging commands encountered when deploying Agent Substrate on GKE.

---

## 1. Node Auto-Provisioning & Custom ComputeClass Issues

### Symptom: Worker Pods remain in `Pending (Unschedulable)`
* **Root Cause**: GKE Cluster Autoscaler / NAP cannot find a node matching the `ComputeClass` specifications, or the required node taints/tolerations do not match.
* **Resolution**:
  1. Verify the `ComputeClass` is in the cluster:
     ```bash
     kubectl get computeclasses
     ```
  2. Inspect the pod scheduling events:
     ```bash
     kubectl describe pod <worker-pod-name> -n demo-agents
     ```
  3. Ensure the `WorkerPool` pod spec includes the exact toleration matching the node taint:
     ```yaml
     tolerations:
     - key: "agent-substrate.io/role"
       operator: "Equal"
       value: "worker"
       effect: "NoSchedule"
     ```

---

## 2. Organization Policy Constraints (Private Clusters & Shielded VMs)

### Symptom: `Cluster creation failed with constraints/compute.vmExternalIpAccess` or `constraints/compute.requireShieldedVm`
* **Root Cause**: Enterprise GCP environments frequently block public IP allocation on VMs and require Shielded VM security flags.
* **Resolution**:
  Always create the cluster with:
  ```bash
  --enable-private-nodes \
  --master-ipv4-cidr=<master-cidr-e.g.-172.16.0.32/28> \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring
  ```

---

## 3. gVisor Memory Checkpoint Incompatibilities (`SIGILL`)

### Symptom: Actor crashes with `SIGILL (Illegal Instruction)` upon resume
* **Root Cause**: Heterogeneous CPU instruction sets. If an actor suspended on an Intel Sapphire Rapids node (C3) attempts to resume on an AMD (N2D/C3D) or older Intel (N1) node, CPU features like AVX-512 available during memory snapshot creation are missing on the target host.
* **Resolution**:
  Enforce a strict, homogeneous CPU family across all worker nodes:
  ```yaml
  apiVersion: cloud.google.com/v1
  kind: ComputeClass
  metadata:
    name: agent-worker-class
  spec:
    nodePoolSettings:
      machineFamily: c3 # Strict C3 Intel Sapphire Rapids
  ```

---

## 4. Ingress Routing: Missing Target Header

### Symptom: `404 Not Found` or `400 Bad Request` from `atenet-router`
* **Root Cause**: The client sent an HTTP request without specifying the target actor header or formatting it incorrectly.
* **Resolution**:
  Substrate Envoy router requires the header in the exact format:
  ```
  ate-target-actor: <atespace>/<actor-name>
  ```
  Example:
  ```bash
  curl -X POST http://${ROUTER_IP}:8080/ \
    -H "ate-target-actor: demo-tenant/devops-agent-1" \
    -d '{"prompt": "Hello"}'
  ```

---

## 5. Workload Identity & Cloud Storage Access Errors

### Symptom: Actor fails to suspend with `403 Forbidden` or `storage: caller does not have permission`
* **Root Cause**: The `atelet` or `ate-api-server` Kubernetes ServiceAccounts lack `roles/storage.objectAdmin` on the snapshot bucket.
* **Resolution**:
  Verify the Workload Identity binding:
  ```bash
  gcloud storage buckets get-iam-policy gs://${BUCKET_NAME}
  ```
  Re-apply the binding if missing:
  ```bash
  gcloud storage buckets add-iam-policy-binding gs://${BUCKET_NAME} \
    --member="principal://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa/atelet" \
    --role="roles/storage.objectAdmin"
  ```
