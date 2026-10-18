# Agent Substrate on Google Kubernetes Engine (GKE)

A comprehensive, production-grade guide, architecture reference, and manifest repository for deploying and operating **Agent Substrate on Google Kubernetes Engine (GKE)**.

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.31%2B%20%7C%20v1.36-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Google Cloud](https://img.shields.io/badge/Google_Cloud-GKE-4285F4?logo=google-cloud&logoColor=white)](https://cloud.google.com/kubernetes-engine)
[![Runtime](https://img.shields.io/badge/Runtime-gVisor%20(runsc)-009688)](https://gvisor.dev/)

---

## Table of Contents
1. [What is Agent Substrate?](#what-is-agent-substrate)
2. [Why Not Just Run 1 Agent per Pod?](#why-not-just-run-1-agent-per-pod)
3. [Core Concepts & Resource Hierarchy](#core-concepts--resource-hierarchy)
4. [Architecture & Request Flow](#architecture--request-flow)
5. [Prerequisites](#prerequisites)
6. [State Store Architecture: In-Cluster PostgreSQL vs. Cloud SQL](#state-store-architecture-in-cluster-postgresql-vs-cloud-sql)
   - [When to Use In-Cluster PostgreSQL (Local / Dev)](#when-to-use-in-cluster-postgresql-local--dev)
   - [When to Use Cloud SQL for PostgreSQL (Enterprise Production & DR)](#when-to-use-cloud-sql-for-postgresql-enterprise-production--dr)
   - [Multi-Region Resilience & Disaster Recovery Matrix](#multi-region-resilience--disaster-recovery-matrix)
7. [Step-by-Step GKE Deployment](#step-by-step-gke-deployment)
   - [Phase 1: VPC & Subnet Preparation](#phase-1-vpc--subnet-preparation)
   - [Phase 2: GKE Standard Cluster Creation](#phase-2-gke-standard-cluster-creation)
   - [Phase 3: Storage & Workload Identity](#phase-3-storage--workload-identity)
   - [Phase 4: Agent Substrate Control Plane Installation](#phase-4-agent-substrate-control-plane-installation)
   - [Phase 5: Externalizing State to Cloud SQL for PostgreSQL (Production)](#phase-5-externalizing-state-to-cloud-sql-for-postgresql-production)
   - [Phase 6: Deploy WorkerPool & ComputeClass](#phase-6-deploy-workerpool--computeclass)
8. [Deploying Your First Agent (Actor)](#deploying-your-first-agent-actor)
9. [Suspend & Resume Lifecycle](#suspend--resume-lifecycle)
10. [Scaling & Sizing Formula](#scaling--sizing-formula)
11. [AI Tool Mesh & MCP Governance (Istio Ambient)](#ai-tool-mesh--mcp-governance-istio-ambient)
12. [Production Best Practices & Pitfalls](#production-best-practices--pitfalls)
13. [Troubleshooting & Verification](#troubleshooting--verification)

---

## What is Agent Substrate?

**Agent Substrate** is a purpose-built agent execution runtime designed to run millions of stateful AI agent sandboxes with **10x to 30x higher density** than standard container runtimes.

AI agents behave very differently from traditional web services:
- **Bursty & I/O-Bound**: Agents spend 90%+ of their lifecycle waiting for LLM completions, human-in-the-loop approvals, or tool I/O.
- **Stateful Sessions**: Agents hold conversation history, tool caches, and filesystem artifacts in local RAM and scratch disks.
- **Security Sandboxing**: Agents generate and execute untrusted code (Python, Bash, SQL) requiring zero-trust kernel isolation.

Substrate bridges the gap between **Kubernetes infrastructure orchestration** and **high-density serverless micro-execution** by dynamically bin-packing hundreds of isolated gVisor (`runsc`) agent sessions ("Actors") inside warm Kubernetes Pods ("Workers").

---

## Why Not Just Run 1 Agent per Pod?

| Dimension | 1 Agent = 1 Pod (Traditional K8s) | Agent Substrate (Actors inside Worker Pods) |
| :--- | :--- | :--- |
| **Startup / Resume Latency** | **5 – 30 seconds** (Scheduling, CNI IP assignment, image pulls) | **100 – 300 milliseconds** (Workers already warm; starts sandbox process) |
| **Cluster Limits** | **Hard ceiling at 15,000 – 30,000 Pods** (etcd, kube-proxy, IPAM exhaustion) | **100,000+ to 500,000 active agents** (K8s only sees worker pool pods) |
| **Idle Cost** | **High** (Idle pods hold reserved RAM/CPU or terminate completely) | **Near zero** (Idle actors hibernate their RAM/disk snapshots to GCS) |
| **State Mobility** | **Difficult** (State locked to Pod PVC; migration requires volume re-attachment) | **Instant Teleport** (Actors resume onto *any* available worker in milliseconds) |
| **Security Isolation** | Relies on namespace or standard runc container isolation | **Kernel-level gVisor (`runsc`) sandbox** with virtualized syscalls |

---

## Core Concepts & Resource Hierarchy

Understanding the relationship between Kubernetes primitives and Substrate primitives is essential:

```
GKE Cluster
 └── Node Pool (Compute Engine VMs, e.g. C3 Sapphire Rapids)
      └── ComputeClass (Governs VM family, Shielded VM, labels)
           └── WorkerPool CRD (Manages fleet of Worker Pods)
                └── Worker (A standard Kubernetes Pod running ateom-gvisor)
                     └── In-Pod Base Container (Runtime supervisor)
                          ├── Actor 1 (gVisor runsc sandbox: Python/Tool session)
                          ├── Actor 2 (gVisor runsc sandbox: Bash session)
                          └── ... up to 100+ Actors bin-packed per Worker
```

### Definitions:
* **`Atespace`**: A multi-tenant administrative boundary or tenant workspace (analogous to a Kubernetes namespace, but for agents).
* **`ActorTemplate`**: Defines the blueprint for an agent — container base image, memory/CPU quotas, environment variables, and idle hibernation timeouts.
* **`Actor`**: A live, stateful instance of an agent running in its own gVisor sandbox.
* **`Worker`**: A single Kubernetes Pod running the `ateom-gvisor` daemon. It hosts multiple Actors simultaneously.
* **`WorkerPool`**: A Kubernetes Custom Resource that scales and manages identical Worker Pod replicas across nodes.
* **`EgressPolicy`**: Granular network policy restricting or allowing actor outbound connectivity (e.g. to Vertex AI, Cloud TPUs, or external APIs).

---

## Architecture & Request Flow

```mermaid
graph TD
    subgraph GKE["GKE Cluster (agent-substrate-cluster)"]
        subgraph CP["Control Plane (ate-system)"]
            subgraph APIPOD["ate-api-server Pod"]
                API["ate-api-server"]
                PROXY["cloud-sql-proxy sidecar<br/>(IAM auth via Workload Identity)"]
            end
            CTRL["ate-controller"]
            ROUTER["atenet-router (Envoy Ingress Gateway)"]
        end

        subgraph NP["Node Pool (C3 Standard VMs)"]
            subgraph NODE1["GKE Node 1 (C3 VM)"]
                DAEMON1["atelet (DaemonSet)"]
                subgraph POD1["Worker Pod 1"]
                    subgraph CONT1["ateom-gvisor supervisor"]
                        ACTOR1["Actor: agent-1 (Active gVisor Sandbox)"]
                        ACTOR2["Actor: agent-2 (Active gVisor Sandbox)"]
                        CAP1["... up to 100 Actors ..."]
                    end
                end
            end

            subgraph NODE2["GKE Node 2 (C3 VM)"]
                DAEMON2["atelet (DaemonSet)"]
                subgraph POD2["Worker Pod 2"]
                    subgraph CONT2["ateom-gvisor supervisor"]
                        ACTOR3["Actor: agent-3 (Active gVisor Sandbox)"]
                        RESUME_TARGET["[Target for Resumed Actors]"]
                    end
                end
            end
        end
    end

    subgraph MANAGED["Managed Google Cloud Services"]
        PG[("Cloud SQL for PostgreSQL<br/>Actor Registry & State")]
        PG_DR[("Cross-Region Read Replica<br/>(optional, set up separately)")]
        GCS[("gs://ate-snapshots-...<br/>RAM & Disk Snapshots")]
    end

    %% Ingress Flow
    USER["Client Application"] -->|"HTTP Request<br/>Header: ate-target-actor: tenant/agent-1"| ROUTER
    ROUTER -->|"Lookup Actor Location"| API
    API -->|"localhost:5432"| PROXY
    PROXY -->|"TLS + IAM token"| PG
    PG -.->|"Optional replication"| PG_DR
    ROUTER -->|"Direct Forward (mTLS)"| POD1
    POD1 -->|"Dispatches into Sandbox"| ACTOR1

    %% External Tool / Model Call
    ACTOR1 -->|"VPC Egress (LLM / TPU / API)"| LLM["LLM Endpoint (Vertex AI / Cloud TPU)"]

    %% Suspend & Resume Flow
    ACTOR1 -.->|"1. Idle Timeout (Suspend RAM/Disk)"| GCS
    GCS -.->|"2. Wake-up Request (Resume onto available Worker)"| RESUME_TARGET
```

---

## Prerequisites

Before starting, ensure you have:
1. **Google Cloud SDK (`gcloud`)** version $\ge$ 480.0.0.
2. **`kubectl`** matching cluster version ($\ge$ 1.30).
3. **`kubectl-ate`** CLI plugin installed.
4. GCP IAM permissions: `roles/container.admin`, `roles/storage.admin`, `roles/iam.serviceAccountAdmin`.
5. A GCP project with billing enabled and the following APIs activated:
   ```bash
   gcloud services enable \
     container.googleapis.com \
     compute.googleapis.com \
     storage.googleapis.com \
     iam.googleapis.com
   ```

---

## State Store Architecture: In-Cluster PostgreSQL vs. Cloud SQL

Agent Substrate relies on a relational state store (`ate-api-server` metadata repository) to track Actor lifecycle states (`Running`, `Suspended`, `Terminated`), active session-to-worker placements, snapshot URIs, and resource accounting.

Substrate supports two operational topologies for this database:

| Feature / Dimension | In-Cluster PostgreSQL (Default Helm/Manifest) | Cloud SQL for PostgreSQL (Enterprise Production) |
| :--- | :--- | :--- |
| **Topology** | Runs inside GKE cluster as a `StatefulSet` with PVC | Managed GCP Service external to GKE cluster |
| **Authentication** | Password or mTLS certs projected via K8s secrets | **Zero-Trust IAM Database Authentication** (no passwords) |
| **High Availability** | Pod restarts / Kubernetes node rescheduling | Optional **Regional HA** (`AVAILABILITY_TYPE=REGIONAL`) with automatic zonal failover |
| **Multi-Region Disaster Recovery** | ❌ **Extremely Difficult**: State trapped on local cluster PVC | Possible with **Cross-Region Read Replicas** (set up separately; not automated here) |
| **Cluster Lifecycle Decoupling** | ❌ Tied to cluster lifecycle: deleting GKE cluster destroys metadata |  Decoupled: Destroying or recreating GKE clusters preserves all agent state |
| **Connection Security** | In-cluster plaintext or self-managed TLS | **TLS 1.3 tunnel via Cloud SQL Auth Proxy sidecar** |
| **Recommended Environment** | Local Kind, Dev/Test, ephemeral POCs | **Tier-1 Enterprise Production (e.g. Banking, Global Telecom)** |

---

### When to Use In-Cluster PostgreSQL (Local / Dev)
- **Fast Local Prototyping**: Ideal for local `kind` clusters, sandbox sandpit environments, or initial developer testing where simplicity and zero GCP bill are prioritized.
- **Single-Zone / Single-Cluster Scope**: Workloads where agent sessions are disposable and catastrophic regional failure does not require automated failover to a secondary site.

### When to Use Cloud SQL for PostgreSQL (Enterprise Production & DR)
- **High Availability & BCM SLAs**: Regulated enterprise environments (e.g. tier-1 financial institutions) mandates strict Business Continuity Management (BCM) and Recovery Time Objectives (RTO < 60s).
- **Multi-Region Cluster Topologies**: When running an active-passive or active-active GKE architecture across paired regions (e.g., London `europe-west2` and Belgium `europe-west1`), Cloud SQL provides **Cross-Region Replication**. If Region A goes dark, the secondary GKE cluster in Region B promotes the read replica and hydrates suspended actors directly from the paired GCS Dual-Region bucket without losing actor session registry state.
- **Zero-Password Security Posture**: Uses GKE Workload Identity and `cloud-sql-proxy` with `CSQL_PROXY_AUTO_IAM_AUTHN=true`, eliminating static credentials from Kubernetes secrets or etcd.

---

## Step-by-Step GKE Deployment

### Phase 1: VPC & Subnet Preparation

GKE clusters running Agent Substrate benefit from a dedicated subnet with Dataplane V2 enabled:

```bash
PROJECT_ID="your-gcp-project"
REGION="us-central1"
ZONE="us-central1-a"
VPC_NAME="agent-vpc"
SUBNET_NAME="agent-substrate-subnet"

# 1. Create VPC network (if not existing)
gcloud compute networks create ${VPC_NAME} --subnet-mode=custom

# 2. Create Subnetwork with secondary ranges for Pods and Services
gcloud compute networks subnets create ${SUBNET_NAME} \
  --network=${VPC_NAME} \
  --region=${REGION} \
  --range=10.60.0.0/20 \
  --secondary-range=agent-pods=10.70.0.0/16,agent-services=10.80.0.0/20
```

### Phase 2: GKE Standard Cluster Creation

Deploy a GKE Standard cluster with **Node Auto-Provisioning (NAP)**, **Dataplane V2**, and the required **Beta mTLS Certificate APIs**:

```bash
CLUSTER_NAME="agent-substrate-cluster"

gcloud container clusters create ${CLUSTER_NAME} \
  --zone=${ZONE} \
  --cluster-version=1.36.4-gke.2046000 \
  --network=${VPC_NAME} \
  --subnetwork=${SUBNET_NAME} \
  --enable-ip-alias \
  --cluster-secondary-range-name=agent-pods \
  --services-secondary-range-name=agent-services \
  --machine-type=c3-standard-4 \
  --num-nodes=3 \
  --enable-dataplane-v2 \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
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
```

> **Why C3 VMs?** GCE C3 machine types (Intel Sapphire Rapids) provide deterministic CPU instruction sets, which is critical for consistent memory checkpointing (`gVisor save/restore`) across different nodes.

### Phase 3: Storage & Workload Identity

Agent Substrate requires a Cloud Storage bucket for saving memory and filesystem snapshots when actors hibernate:

```bash
BUCKET_NAME="ate-snapshots-${PROJECT_ID}-${REGION}"

# 1. Create GCS bucket
gcloud storage buckets create gs://${BUCKET_NAME} \
  --location=${REGION} \
  --uniform-bucket-level-access

# 2. Grant Workload Identity permissions to atelet and ate-api-server
gcloud storage buckets add-iam-policy-binding gs://${BUCKET_NAME} \
  --member="principal://iam.googleapis.com/projects/$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa/atelet" \
  --role="roles/storage.objectAdmin"

gcloud storage buckets add-iam-policy-binding gs://${BUCKET_NAME} \
  --member="principal://iam.googleapis.com/projects/$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa/ate-api-server" \
  --role="roles/storage.objectAdmin"
```

### Phase 4: Agent Substrate Control Plane Installation

Apply the Substrate control plane manifests:

```bash
# Apply namespaces, CRDs, and controllers
kubectl apply -k manifests/ate-install/
```

Verify all control plane pods are running:
```bash
kubectl get pods -n ate-system
```
Expected output (default in-cluster dev mode):
```
NAME                                           READY   STATUS    RESTARTS   AGE
ate-api-server-7b9c6f89b-8x2lq                 1/1     Running   0          2m
ate-controller-5df84b7f4-m9xpk                 1/1     Running   0          2m
atenet-egress-84c688d66-r2zlw                  1/1     Running   0          2m
atenet-router-69c76b9f4f-4tk2b                 1/1     Running   0          2m
atelet-d5m8x                                   1/1     Running   0          2m
atelet-x9p12                                   1/1     Running   0          2m
atelet-y8q43                                   1/1     Running   0          2m
pod-certificate-controller-74f4c9c4db-9zk5x    1/1     Running   0          2m
postgres-0                                     2/2     Running   0          2m
```

### Phase 5: Externalizing State to Cloud SQL for PostgreSQL (Production)

The default install keeps `ate-api-server`'s state in the in-cluster `postgres-0` StatefulSet. For production, move it to Cloud SQL for PostgreSQL. `ate-api-server` reaches Cloud SQL through the Cloud SQL Auth Proxy sidecar, and the proxy authenticates as a Google service account (GSA) through Workload Identity using IAM database authentication. No database password is stored in the cluster.

**Before you start:** suspend every actor (`kubectl ate get actors -a <atespace>`, then `kubectl ate suspend actor ...`). The copy needs a quiesced control plane with no actor assigned to a worker; the script checks this and stops if any actor is still running. Expect a few minutes of control-plane downtime while the data is copied.

```bash
PROJECT_ID=your-gcp-project REGION=us-central1 ./scripts/setup-cloudsql.sh
```

Optional settings: `INSTANCE_NAME`, `DB_NAME` (default `atepg`), `DB_VERSION` (default `POSTGRES_15`), `AVAILABILITY_TYPE` (`ZONAL` by default; use `REGIONAL` for HA), `GSA_NAME`, `BUCKET_NAME`, and `MIGRATE_DATA=false` to start with an empty database instead of copying.

What [`scripts/setup-cloudsql.sh`](scripts/setup-cloudsql.sh) does. It is idempotent and safe to re-run:

1. **Backs up** the current `ate-api-server` Secret, ConfigMap and Deployment to a local `cloudsql-backup-<timestamp>/` directory.
2. **Provisions** the Cloud SQL instance with `cloudsql.iam_authentication=on`, plus the database, if they don't exist.
3. **Sets up identity:**
   - creates the GSA and grants it `roles/cloudsql.client` and `roles/cloudsql.instanceUser`
   - binds Workload Identity to `ate-system/ate-api-server` and annotates that ServiceAccount
   - grants the GSA `storage.objectAdmin` and `storage.bucketViewer` on the snapshot bucket
4. **Creates the IAM database user** and runs the one-time `GRANT CREATE` on the database and `public` schema. It uses a temporary `postgres` password that is scrambled when the script exits.
5. **Copies the data**, if the target database is empty and `postgres-0` is in use:
   - scales `ate-api-server` to 0 and dumps `postgres-0`
   - restores the dump in a single transaction as the IAM user, so that user owns every table
   - checks that every table's row count matches
   - on any mismatch or error, scales `ate-api-server` back up on the in-cluster database and stops
   - never overwrites a database that already has tables
6. **Switches `ate-api-server` to Cloud SQL:**
   - writes the connection string to the Secret `ate-api-server-secret-envvars`
   - writes the proxy settings to the ConfigMap `ate-api-server-envvars`
   - injects the sidecar from [`proxy-sidecar-patch.yaml`](manifests/ate-install/cloudsql/proxy-sidecar-patch.yaml) and rolls out the pods
7. **Verifies the switch**, and fails if any check doesn't pass:
   - each pod's proxy has accepted connections
   - `ate-api-server` reports `PostgreSQL migrations ready`
   - Cloud SQL shows sessions from the IAM user
   - `postgres-0` has **no** connections from `ate-api-server`

> [!IMPORTANT]
> **Three things that break this migration if done by hand:**
> 1. **The connection string lives in the Secret, not the ConfigMap.** `ate-api-server` reads the ConfigMap first and the Secret second, so the Secret wins. Changing only the ConfigMap leaves `ate-api-server` on `postgres-0` while the proxy sidecar sits idle.
> 2. **Cloud SQL IAM users start with no privileges.** PostgreSQL 15 and later removed `CREATE` on the `public` schema for regular users. Without the one-time `GRANT`, `ate-api-server` fails with `permission denied for schema public`.
> 3. **Annotating the ServiceAccount with a GSA changes `ate-api-server`'s Cloud Storage identity too.** If the GSA lacks the snapshot-bucket roles, suspends fail with `PermissionDenied ... storage.objects.list`.

Check the result yourself:

```bash
# Both replicas run the ateapi container plus the cloud-sql-proxy sidecar (2/2)
kubectl get pods -n ate-system -l app=ate-api-server

# The proxy is carrying ateapi's database traffic
kubectl logs -n ate-system deploy/ate-api-server -c cloud-sql-proxy | grep "Accepted connection"

# The in-cluster database no longer has connections from ate-api-server
kubectl exec -n ate-system postgres-0 -c postgres -- \
  psql -U postgres -d atepg -c "select client_addr, count(*) from pg_stat_activity where datname='atepg' group by 1;"

# A suspend and resume round trip works end to end
kubectl ate suspend actor <name> -a <atespace> && kubectl ate resume actor <name> -a <atespace>
```

**Rollback:** `postgres-0` is left untouched. To return to it, run `kubectl apply -f cloudsql-backup-<timestamp>/secret.yaml && kubectl -n ate-system rollout restart deployment/ate-api-server`. Changes made after the switch exist only in Cloud SQL. When you are confident, stop the in-cluster database with `kubectl -n ate-system scale statefulset postgres --replicas=0`, and keep its PVC until you are sure you no longer need it.

> [!NOTE]
> The script covers a single Cloud SQL instance. HA failover drills and cross-region read replicas for disaster recovery are separate steps that this repository does not automate.

### Phase 6: Deploy WorkerPool & ComputeClass

Create the Custom ComputeClass so GKE Node Auto-Provisioning automatically provisions C3 nodes for Workers:

```yaml
# manifests/computeclass-agent-worker.yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: agent-worker-class
spec:
  nodePoolSettings:
    machineFamily: c3
    labels:
      agent-substrate.io/role: worker
    taints:
      - key: agent-substrate.io/role
        value: worker
        effect: NoSchedule
```

Create the `WorkerPool` with sizing for up to 100 actors per worker:

```yaml
# manifests/workerpool-c3.yaml
apiVersion: substrate.google.com/v1alpha1
kind: WorkerPool
metadata:
  name: c3-agent-workers
  namespace: demo-agents
spec:
  replicas: 2
  template:
    metadata:
      labels:
        agent-substrate.io/role: worker
    spec:
      tolerations:
      - key: "agent-substrate.io/role"
        operator: "Equal"
        value: "worker"
        effect: "NoSchedule"
      containers:
      - name: worker
        image: us-docker.pkg.dev/gke-substrate-release/substrate/ateom-gvisor:v0.2.0-gke.0
        resources:
          requests:
            cpu: "8"
            memory: "28Gi"
          limits:
            cpu: "12"
            memory: "32Gi"
        env:
        - name: ATEOM_MAX_ACTORS
          value: "100"
```

Apply both manifests:
```bash
kubectl apply -f manifests/computeclass-agent-worker.yaml
kubectl apply -f manifests/workerpool-c3.yaml
```

---

## Deploying Your First Agent (Actor)

### 1. Create the Tenant Space (`Atespace`)
```yaml
# manifests/demo-tenant.yaml
apiVersion: substrate.google.com/v1alpha1
kind: Atespace
metadata:
  name: demo-tenant
```

### 2. Define the Agent Template (`ActorTemplate`)
```yaml
# manifests/actortemplate-python.yaml
apiVersion: substrate.google.com/v1alpha1
kind: ActorTemplate
metadata:
  name: python-agent
  namespace: demo-tenant
spec:
  idleTimeout: "30s" # Hibernate to GCS after 30 seconds of inactivity
  resources:
    requests:
      cpu: "100m"
      memory: "256Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
  template:
    spec:
      containers:
      - name: agent
        image: python:3.11-slim
        command: ["python3", "-u", "-c"]
        args:
        - |
          import http.server, socketserver, json, os
          class Handler(http.server.SimpleHTTPRequestHandler):
              def do_POST(self):
                  length = int(self.headers.get('content-length', 0))
                  body = self.rfile.read(length).decode('utf-8')
                  resp = {"status": "ok", "echo": body, "pid": os.getpid()}
                  self.send_response(200)
                  self.send_header('Content-Type', 'application/json')
                  self.end_headers()
                  self.wfile.write(json.dumps(resp).encode('utf-8'))
          with socketserver.TCPServer(("", 8080), Handler) as httpd:
              httpd.serve_forever()
        ports:
        - containerPort: 8080
```

### 3. Create the Actor
```yaml
# manifests/actor-devops-1.yaml
apiVersion: substrate.google.com/v1alpha1
kind: Actor
metadata:
  name: devops-agent-1
  namespace: demo-tenant
spec:
  templateRef:
    name: python-agent
```

Apply:
```bash
kubectl apply -f manifests/demo-tenant.yaml
kubectl apply -f manifests/actortemplate-python.yaml
kubectl apply -f manifests/actor-devops-1.yaml
```

### 4. Send Traffic to the Actor
Routing is handled through the `atenet-router` Envoy gateway. The target actor is specified using the `ate-target-actor` header:

```bash
ROUTER_IP=$(kubectl get svc atenet-router -n ate-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -X POST http://${ROUTER_IP}:8080/ \
  -H "Host: atenet-router.ate-system.svc.cluster.local" \
  -H "ate-target-actor: demo-tenant/devops-agent-1" \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello from Agent Substrate!"}'
```

---

## Suspend & Resume Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Scheduled: Actor Created
    Scheduled --> Active: Dispatched to Worker Pod
    Active --> Idle: Request Finished
    Idle --> Active: New Request Arrives (Instant <5ms)
    Idle --> Suspending: Idle Timeout Breached (30s)
    Suspending --> Suspended: State checkpointed to GCS
    Suspended --> Resuming: Request with ate-target-actor header
    Resuming --> Active: Restored to ANY warm Worker (100-300ms)
    Active --> [*]: Actor Terminated
```

1. **Active**: The Actor runs inside a gVisor `runsc` sandbox on Worker 1.
2. **Idle**: The turn finishes. CPU usage drops to 0, but RAM and file state remain resident.
3. **Suspending**: When `idleTimeout` (e.g. 30s) expires without traffic, `ateom` initiates a gVisor memory and disk checkpoint, streaming the snapshot bundle directly to `gs://${BUCKET_NAME}`.
4. **Suspended**: The sandbox on Worker 1 is torn down. Memory is freed for other actors. The actor consumes **\$0.00 compute**.
5. **Resume (Instant Teleport)**: A new message arrives at `atenet-router`. The router parks the HTTP connection, queries `ate-api-server`, streams the state bundle onto an available worker (e.g. Worker 2), unpauses the process at the exact memory instruction, and completes the HTTP request in **150–300ms**.

---

## Scaling & Sizing Formula

### How Many Actors per Worker?

Use the sizing formula:
$$\text{Max Actors per Worker} = \min\left( \frac{\text{Worker RAM} - \text{Overhead}}{\text{Peak Working-Set RAM per Actor}}, \; \frac{\text{Worker vCPUs} \times \text{Oversubscription Factor}}{\text{Active Compute CPU per Actor}} \right)$$

### Sizing Cheat Sheet:

| Workload Type | RAM / Actor | CPU Usage Profile | Target Density | Worker Pod Sizing |
| :--- | :--- | :--- | :--- | :--- |
| **Conversational / TAM Agent** (API calls, tool I/O) | 64 – 128 MiB | Ultra-low (95% I/O wait) | **150 – 250 actors** | 4 vCPU, 16–32 GB RAM |
| **DevOps / Script Execution** (bash, git, curl, jq) | 256 MiB | Moderate bursts | **80 – 100 actors** | 8 vCPU, 32 GB RAM |
| **Data Analysis Agent** (Python, pandas, duckdb) | 512 MiB – 1 GiB | High compute bursts | **25 – 50 actors** | 8–16 vCPU, 32–64 GB RAM |

### How an Actor Surge Triggers a Compute Node
1. **Saturation**: Existing Worker Pods reach memory limit or `ATEOM_MAX_ACTORS`.
2. **WorkerPool Scaling**: HPA or Substrate autoscaler creates new Worker Pods.
3. **Pending State**: If existing nodes lack capacity, the new Worker Pods enter `Pending (Unschedulable)`.
4. **Node Auto-Provisioning (NAP)**: Detects pending pods with `ComputeClass/agent-worker-class` and calls GCE APIs to spin up new `c3-standard-4` VMs.
5. **Pod Binding**: Once the VM joins the cluster, the Worker Pod starts, and actors resume immediately.

---

## AI Tool Mesh & MCP Governance (Istio Ambient)

When agents scale beyond running isolated sandbox code and begin calling backend enterprise APIs, databases, and microservices via the **Model Context Protocol (MCP)**, platform teams must solve **tool governance, runaway loop protection, and auditability**.

Traditional service mesh sidecars add ~100MB RAM and 0.1 vCPU per container, destroying Agent Substrate's compute density. This repository provides a reference architecture using **Istio Ambient Mesh (ztunnel + Waypoint)** to enforce L7 tool security **without injecting sidecars** into agent worker pods.

```
Agent Substrate Worker Pod                     Istio Ambient Data Plane                Model Context Protocol (MCP) Tools
+-------------------------------+              +------------------------+              +---------------------------------+
| Actor (Finance Agent)         |              | L4 ztunnel (DaemonSet) |              | Waypoint Proxy (mcp-tools NS)   |
| - Principal: sa-agent-finance +-[mTLS HBONE]->                      +-[mTLS HBONE]-> - Enforces RBAC Policy          |
+-------------------------------+  (Port 15008)| - Zero-sidecar tax     |  (Port 15008)| - Token-Bucket Rate Limiter     |
                                               +------------------------+              | - Google Cloud Trace Exporter   |
                                                                                       +----------------+----------------+
                                                                                                        |
                                                                                       +----------------v----------------+
                                                                                       | Backend MCP Tool Services       |
                                                                                       | * currency-tool (ALLOWED: 200)  |
                                                                                       | * database-tool (ALLOWED: 200)  |
                                                                                       +---------------------------------+
```

### The 5 Governance Pillars

1. **Least-Privilege Tool RBAC**: Uses Istio `AuthorizationPolicy` targeting backend services. Only authenticated agent service accounts can invoke sensitive tools (e.g. `sa-agent-finance` can call `currency-tool`, while `sa-agent-support` receives an instant `403 Forbidden`).
2. **Runaway Agent Rate Limiting**: Injects Envoy token-bucket filters (10 req/s) at the Waypoint to protect downstream APIs from infinite LLM retry loops.
3. **Distributed Cloud Trace Telemetry**: Attaches W3C `traceparent` headers with `ai.mcp.tool` and `ai.agent.principal` tags, exporting complete spans directly to Google Cloud Trace.
4. **Sidecarless Zero-Trust mTLS**: Enforces mutual TLS with cryptographic SPIFFE identities using node-level ztunnels and HBONE (HTTP-based Overlay Network) over port 15008.
5. **Gateway API Protocol Routing**: Standard Kubernetes Gateway API `HTTPRoute` resources managing health checks, timeouts (30s), and path routing for JSON-RPC 2.0 MCP tools.

### Deploying & Testing the AI Mesh

The manifests and automation scripts are located in [`manifests/ai-mesh/`](manifests/ai-mesh/):

```bash
# 1. Deploy Ambient mesh, Waypoint proxies, and mock MCP tools
./manifests/ai-mesh/deploy-ai-mesh.sh

# 2. Run the automated test battery verifying all 5 pillars
./manifests/ai-mesh/verify-ai-mesh.sh
```

For full details on manifests, CRDs, and configurations, see the [AI Mesh Documentation](manifests/ai-mesh/README.md).

---

## Production Best Practices & Pitfalls

### 1. Externalize State for Multi-Region Disaster Recovery
> [!IMPORTANT]
> Never run in-cluster PostgreSQL `StatefulSet` in multi-region production clusters. A cluster loss or regional outage traps all actor metadata on local PVCs. Always externalize state to **Cloud SQL for PostgreSQL with Cross-Region Read Replicas** paired with **Dual-Region GCS buckets** for actor memory snapshots.

### 2. Homogeneous CPU Architectures
> [!IMPORTANT]
> Always pin your Worker node pools to a homogeneous CPU family (e.g. exclusively Google Compute Engine **C3** Intel Sapphire Rapids). 
> Restoring a gVisor memory snapshot taken on an Intel CPU onto an AMD (or older Intel) node can cause CPU instruction set mismatches (`SIGILL` Illegal Instruction).

### 2. Private Clusters & Shielded VMs
- Ensure `--enable-private-nodes` is enabled.
- Enforce `--shielded-secure-boot` and `--shielded-integrity-monitoring` to comply with enterprise Org Policies.

### 3. Dedicated Secondary IP Ranges
- Avoid running out of Pod IPs. For high-density setups, ensure your Pod secondary subnet CIDR is at least `/16` (65,536 IPs).

### 4. Granular Egress Policies
- Agents generating arbitrary code must never have unrestricted access to VPC internal services. Use Substrate `EgressPolicy` CRDs to whitelist only required endpoints (e.g., Cloud TPU port 8000, Vertex AI, or specific internet APIs).

### 5. Idle Timeout Tuning
- Set `idleTimeout: "30s"` to `"60s"` for interactive multi-turn chat applications to avoid thrashing snapshots between closely spaced user turns.
- Set `idleTimeout: "10s"` for batch or background agents to immediately reclaim worker memory.

---

## Troubleshooting & Verification

### Helpful Commands:
```bash
# Check status of Substrate control plane
kubectl get pods -n ate-system

# Check active workers and their allocated actor density
kubectl ate get workers

# Check status of registered actors
kubectl ate get actors -n demo-tenant

# Stream logs from a specific actor
kubectl ate logs devops-agent-1 -n demo-tenant -f

# Force suspend an actor manually
kubectl ate suspend devops-agent-1 -n demo-tenant

# Force resume an actor manually
kubectl ate resume devops-agent-1 -n demo-tenant
```

---

## License
Apache License 2.0. See [LICENSE](LICENSE) for details.
