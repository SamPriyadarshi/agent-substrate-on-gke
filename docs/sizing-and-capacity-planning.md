# Agent Sizing & Capacity Planning Guide

This guide provides mathematical formulas, memory sizing benchmarks, and architecture best practices for determining how many **Actors** should run inside a single **Worker Pod** in Agent Substrate.

---

## 1. The Core Sizing Formula

The maximum number of concurrent active actors a Worker Pod can host is governed by:

$$\text{Max Actors per Worker} = \min\left( \frac{\text{Worker RAM} - \text{Worker Overhead}}{\text{Peak Working-Set RAM per Actor}}, \; \frac{\text{Worker vCPUs} \times \text{Oversubscription Factor}}{\text{Active Compute CPU per Actor}} \right)$$

Where:
* **$\text{Worker RAM}$**: Total Kubernetes memory request/limit for the `ateom-gvisor` Pod (e.g. 32 GiB).
* **$\text{Worker Overhead}$**: Memory reserved for the host OS, Envoy sidecar, and `ateom` runtime supervisor ($\approx 2 \text{ to } 3 \text{ GiB}$).
* **$\text{Peak Working-Set RAM}$**: The maximum resident set size (RSS) of the agent process during turn execution.
* **$\text{Oversubscription Factor}$**: Ratio allowable based on whether actors are I/O bound ($5\times - 10\times$) or compute bound ($1.5\times - 2\times$).

---

## 2. Workload Archetypes

### Archetype A: Conversational & Tool Calling Agents (I/O Heavy)
* **Behavior**: The agent receives a user prompt, makes external API calls to Gemini / Vertex AI / Cloud TPU, and returns responses.
* **RAM / Actor**: 64 MiB – 128 MiB.
* **CPU Profile**: 95%+ idle waiting on external HTTP responses.
* **Recommended Density**: **150 – 250 actors** per 32 GiB Worker Pod.
* **Worker Pod Sizing**: `requests: {cpu: "4", memory: "16Gi"}` to `limits: {cpu: "8", memory: "32Gi"}`.

### Archetype B: DevOps & CLI Automation Agents
* **Behavior**: The agent clones git repos, runs shell commands (`curl`, `jq`, `gcloud`, `sed`), and writes local logs.
* **RAM / Actor**: 256 MiB.
* **CPU Profile**: Short bursts of CPU during script runs.
* **Recommended Density**: **80 – 100 actors** per 32 GiB Worker Pod.
* **Worker Pod Sizing**: `requests: {cpu: "8", memory: "28Gi"}` to `limits: {cpu: "12", memory: "32Gi"}`.

### Archetype C: Data Science & Code Execution Agents
* **Behavior**: The agent executes arbitrary Python code using heavy libraries (`pandas`, `numpy`, `duckdb`, `matplotlib`).
* **RAM / Actor**: 512 MiB – 1 GiB.
* **CPU Profile**: Sustained compute spikes during data processing.
* **Recommended Density**: **25 – 50 actors** per 32 GiB Worker Pod.
* **Worker Pod Sizing**: `requests: {cpu: "8", memory: "32Gi"}` to `limits: {cpu: "16", memory: "64Gi"}`.

---

## 3. Worker Pod vs. Actor Density Math

| Worker Pod RAM | Reserved Overhead | Available RAM | @ 128 MiB / Actor | @ 256 MiB / Actor | @ 512 MiB / Actor |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **16 GiB** | 2 GiB | 14 GiB | **112 Actors** | **56 Actors** | **28 Actors** |
| **32 GiB** | 3 GiB | 29 GiB | **232 Actors** | **116 Actors** | **58 Actors** |
| **64 GiB** | 4 GiB | 60 GiB | **480 Actors** | **240 Actors** | **120 Actors** |

---

## 4. Blast Radius Considerations

While Agent Substrate technically allows up to 1,000 actors inside one mega-pod:
- **Anti-Pattern**: Hosting 1,000 actors on a single 128 GiB Pod means any worker pod eviction or node crash disrupts 1,000 concurrent user sessions.
- **Recommended Best Practice**: Target **50 to 150 actors** per Worker Pod. Scale horizontally using `WorkerPool.spec.replicas` or HPA across multiple GKE nodes. This provides high resilience, rolling update safety, and fast snapshot transfer times.
