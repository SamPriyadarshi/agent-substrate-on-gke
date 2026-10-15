# AI Tool Mesh & MCP Governance (Istio Ambient)

This directory contains the production reference implementation for **AI Tool Networking, Model Context Protocol (MCP) Governance, and Security Policies** on Google Kubernetes Engine (GKE) running alongside **Agent Substrate**.

---

## Why an AI Mesh?

When autonomous agents scale from running isolated scripts to interacting with corporate databases, APIs, and tools, platform engineering teams encounter critical operational risks:
1. **Runaway Agent Loops**: A hallucinating agent stuck in a recursive loop can overwhelm backend tools with thousands of requests per second.
2. **Confused Deputy & Unauthorized Tool Access**: An agent intended for generic user support could attempt to call financial or database mutation tools.
3. **The Sidecar Tax**: Injecting traditional Envoy sidecars into high-density worker pods adds ~100MB RAM and 0.1 vCPU per container, destroying compute density.
4. **Lack of Auditability**: Blind calls across agent sandboxes make it impossible to trace which LLM prompt triggered which database query.

**Solution**: **Istio Ambient Mesh (ztunnel + Waypoint)** provides L4 mTLS and L7 policy enforcement **without injecting sidecars** into agent worker pods.

---

## The 5 Pillars of AI Tool Governance

| Pillar | Architecture Pattern | Implementation in this Directory |
| :--- | :--- | :--- |
| **1. Identity & RBAC** | Least-privilege tool authorization | `policies/03-security-and-authz.yaml`: Grants `sa-agent-finance` access to `currency-tool` and `database-tool`, while denying `sa-agent-support` (HTTP 403). |
| **2. Runaway Protection** | Token-bucket rate limiting & circuit breaking | `gateway-api/04-routes-and-resilience.yaml`: Injects Envoy token-bucket limiter (10 req/s) and outlier detection to prevent tool API saturation. |
| **3. Distributed Tracing** | W3C trace context & prompt attribution | `tracing/05-cloud-trace-telemetry.yaml`: Telemetry CRD exporting distributed traces with `ai.mcp.tool` and `ai.agent.principal` tags to **Google Cloud Trace**. |
| **4. Zero-Trust Security** | Sidecarless L4/L7 encryption | `istio-ambient/02-waypoint-gateway.yaml`: Ambient Waypoint proxy enforcing mTLS over HBONE (port 15008) at the service boundary. |
| **5. Protocol Routing** | Kubernetes Gateway API (HTTPRoute) | `gateway-api/04-routes-and-resilience.yaml`: Standard `HTTPRoute` handling timeouts (30s) and health-checked path routing for Model Context Protocol (MCP) JSON-RPC endpoints. |

---

## Directory Structure

```
manifests/ai-mesh/
├── deploy-ai-mesh.sh                     # Automated 1-click deployment script
├── verify-ai-mesh.sh                     # Automated test battery verifying all 5 pillars
├── istio-ambient/
│   └── 02-waypoint-gateway.yaml         # L7 Waypoint Gateway for mcp-tools namespace
├── policies/
│   └── 03-security-and-authz.yaml       # Strict mTLS & AuthorizationPolicies
├── gateway-api/
│   └── 04-routes-and-resilience.yaml    # HTTPRoutes, DestinationRules & EnvoyFilters
├── tracing/
│   └── 05-cloud-trace-telemetry.yaml    # Cloud Trace OpenTelemetry exporter
└── mock-tools/
    ├── 00-namespaces-and-identities.yaml # mcp-tools & ate-workers namespaces + KSAs
    ├── 01-mcp-tools-deployments.yaml     # Currency, Database, and Search MCP tools
    ├── 06-agent-workloads.yaml          # Test agent workloads (Finance vs Support)
    └── mcp_server.py                    # Lightweight Python JSON-RPC 2.0 MCP server
```

---

## Quickstart

### 1. Deploy the AI Mesh & Mock Tools
```bash
./manifests/ai-mesh/deploy-ai-mesh.sh
```

### 2. Run the Verification Battery
```bash
./manifests/ai-mesh/verify-ai-mesh.sh
```

Expected verification output:
- **Pillar 1 Test**: Finance Agent calls Currency Tool $\rightarrow$ `ALLOW (200 OK)`. Support Agent calls Currency Tool $\rightarrow$ `DENY (403 Forbidden)`.
- **Pillar 2 Test**: 15 rapid requests from Finance Agent $\rightarrow$ First 10 allowed, subsequent 5 rate-limited with `x-rate-limited: true`.
- **Pillar 3 & 5 Test**: Waypoint Envoy logs show JSON-RPC method routing and W3C traceparents.
- **Pillar 4 Test**: `istioctl ztunnel-config` confirms active HBONE mTLS connections.
