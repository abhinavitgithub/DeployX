# DeployX — Kubernetes Deployment & Blue-Green Architecture

## Overview

DeployX utilizes declarative Kubernetes manifests to deploy onto a local **Kind** (Kubernetes in Docker) cluster (`deployx`). The platform orchestrates the FastAPI health telemetry backend in a zero-downtime **Blue-Green** deployment configuration and an Nginx frontend reverse proxy inside an isolated namespace (`deployx`), utilizing container health probes, strict resource limits, internal ClusterIP service routing, and automated traffic switching.

---

## Architecture & Cluster Topology

```
+-------------------------------------------------------------------------------------------------+
| Kind Cluster: deployx (v1.34.0)                                                                 |
| Namespace: deployx                                                                              |
|                                                                                                 |
|   +-----------------------------------------------------------------------------------------+   |
|   | External Access / Host Port Mapping                                                     |   |
|   | NodePort: 30080  |  kubectl port-forward svc/deployx-frontend 8080:80                   |   |
|   +--------------------------------------------+--------------------------------------------+   |
|                                                |                                                |
|                                                v                                                |
|   +-----------------------------------------------------------------------------------------+   |
|   | Service: deployx-frontend (NodePort: 80 -> NodePort 30080)                             |   |
|   | Selector: app: deployx-frontend                                                        |   |
|   +--------------------------------------------+--------------------------------------------+   |
|                                                |                                                |
|                                                v                                                |
|   +-----------------------------------------------------------------------------------------+   |
|   | Pod: deployx-frontend-xxxx (1/1 Running)                                                |   |
|   | Container: frontend (nginx:alpine)                                                      |   |
|   | Serves: Static dashboard assets (HTML, CSS, JS)                                         |   |
|   | Proxies: /health/, /api/, /metrics, /docs to upstream 'http://backend:8000'            |   |
|   +--------------------------------------------+--------------------------------------------+   |
|                                                |                                                |
|                          Dynamic Upstream Service Routing                                       |
|                       (DNS resolution for hostname 'backend')                                   |
|                                                |                                                |
|                   +----------------------------+----------------------------+                   |
|                   |                                                         |                   |
|                   v                                                         v                   |
|   +------------------------------------+                    +-------------------------------+   |
|   | Service: backend (Active Router)   |                    | Service: deployx-backend      |   |
|   | Type: ClusterIP (Port 8000)        |                    | Type: ClusterIP (Port 8000)   |   |
|   | Dynamic Selector:                  |                    | Static Selector:              |   |
|   |   app: deployx-backend             |                    |   app: deployx-backend        |   |
|   |   deployment-color: [blue | green] |                    | (Canonical Service)           |   |
|   +-----------------+------------------+                    +---------------+---------------+   |
|                     |                                                       |                   |
|         +-----------+-----------+                                           |                   |
|         |                       |                                           |                   |
|  (When Selector=blue)   (When Selector=green)                               |                   |
|         |                       |                                           |                   |
|         v                       v                                           |                   |
|   +--------------------+  +--------------------+                            |                   |
|   | Deployment: Blue   |  | Deployment: Green  |                            |                   |
|   | deployx-backend    |  | deployx-backend-   |                            |                   |
|   |                    |  |   green            |                            |                   |
|   | Pod: 1/1 Running   |  | Pod: 1/1 Running   |                            |                   |
|   | Label: color=blue  |  | Label: color=green |                            |                   |
|   +--------------------+  +--------------------+                            |                   |
|         ^                                                                   ^                   |
|         +-------------------------------------------------------------------+                   |
+-------------------------------------------------------------------------------------------------+
```

---

## Manifest Specifications

All manifests are located in `infrastructure/kubernetes/`:

```text
infrastructure/kubernetes/
├── namespace.yaml          # Dedicated 'deployx' namespace
├── backend.yaml            # Backend Blue Deployment (1 replica) + ClusterIP Service (deployx-backend)
├── backend-green.yaml      # Backend Green Deployment (1 replica)
├── backend-alias.yaml      # Dynamic routing Service ('backend') with deployment-color selector
└── frontend.yaml           # Frontend Deployment (1 replica) + NodePort Service (deployx-frontend)
```

### 1. Namespace (`namespace.yaml`)
- **Name:** `deployx`
- **Labels:** `app.kubernetes.io/part-of: deployx`

### 2. Backend Blue Deployment & Service (`backend.yaml`)
- **Deployment Name:** `deployx-backend`
- **Replicas:** 1
- **Labels:** `app: deployx-backend`, `deployment-color: blue`
- **Image:** `deployx-backend:latest` (`imagePullPolicy: IfNotPresent`)
- **Container Port:** 8000 (`http`)
- **Probes:**
  - **Readiness:** HTTP GET `/health/ready` on port `http` (initial delay: 5s, period: 10s)
  - **Liveness:** HTTP GET `/health/live` on port `http` (initial delay: 10s, period: 20s)
- **Resource Constraints:**
  - **Requests:** CPU `100m`, Memory `128Mi`
  - **Limits:** CPU `500m`, Memory `384Mi`
- **Primary Service:** `deployx-backend` (ClusterIP, Port `8000` $\rightarrow$ TargetPort `8000`, selector `app: deployx-backend`)

### 3. Backend Green Deployment (`backend-green.yaml`)
- **Deployment Name:** `deployx-backend-green`
- **Replicas:** 1
- **Labels:** `app: deployx-backend`, `deployment-color: green`
- **Image:** `deployx-backend:latest` (`imagePullPolicy: IfNotPresent`)
- **Container Port:** 8000 (`http`)
- **Probes & Resources:** Identical to Blue environment (CPU: `100m`/`500m`, RAM: `128Mi`/`384Mi`, liveness and readiness probes enabled).

### 4. Dynamic Backend Routing Service (`backend-alias.yaml`)
- **Service Name:** `backend`
- **Type:** `ClusterIP`
- **Port:** `8000` $\rightarrow$ TargetPort `8000`
- **Selector:**
  - `app: deployx-backend`
  - `deployment-color: blue` *(dynamically switched to `green` or back via controller)*
- **Architectural Rationale:** The frontend Nginx reverse proxy configuration (`frontend/nginx.conf`) routes requests to `http://backend:8000`. By mutating `backend` Service's selector between `deployment-color: blue` and `deployment-color: green`, traffic switches instantly with zero downtime, zero proxy reloads, and zero container rebuilds.

### 5. Frontend Deployment & Service (`frontend.yaml`)
- **Deployment Name:** `deployx-frontend`
- **Replicas:** 1
- **Image:** `deployx-frontend:latest` (`imagePullPolicy: IfNotPresent`)
- **Container Port:** 80 (`http`)
- **Probes:**
  - **Readiness:** HTTP GET `/` on port `http` (initial delay: 3s, period: 10s)
  - **Liveness:** HTTP GET `/` on port `http` (initial delay: 10s, period: 20s)
- **Resource Constraints:**
  - **Requests:** CPU `50m`, Memory `32Mi`
  - **Limits:** CPU `250m`, Memory `128Mi`
- **Service:** `deployx-frontend` (NodePort, Port `80` $\rightarrow$ TargetPort `80`, NodePort: `30080`)

---

## Blue-Green Traffic Controller (`switch_traffic.sh`)

DeployX includes an automated traffic switching and verification controller: [`scripts/linux/switch_traffic.sh`](../../scripts/linux/switch_traffic.sh).

### Controller Operational Logic
1. **Argument Validation:** Enforces strict argument input (`blue` or `green`, case-insensitive).
2. **Pre-flight Health Checks:**
   - Verifies target deployment existence in namespace `deployx`.
   - Runs `kubectl rollout status` with a 30-second timeout.
   - Inspects `.status.readyReplicas` ensuring $\ge$ 1 healthy replica before initiating cutover.
3. **Idempotency Guard:** Detects if traffic is already pointing to the target color and safely exits early with code 0.
4. **Zero-Downtime Cutover:** Patches the `backend` Service selector:
   ```json
   {"spec":{"selector":{"app":"deployx-backend","deployment-color":"<target>"}}}
   ```
5. **Endpoint Verification:** Polls active IP endpoints on `service/backend` with configurable timeout (`DEPLOYX_ENDPOINT_TIMEOUT`, default 15s).
6. **Automated Rollback on Failure:** If healthy endpoints fail to materialize within the timeout window, the controller automatically reverts the `backend` Service selector to the previous known-good color and exits with code 1.

### Usage Examples

```bash
# Switch active traffic to Green environment
./scripts/linux/switch_traffic.sh green

# Switch active traffic back to Blue environment
./scripts/linux/switch_traffic.sh blue

# Check active traffic routing and endpoints
kubectl get endpoints -n deployx backend
```

---

## Deployment & Verification Workflow

### 1. Build and Load Images into Kind

```bash
# Build images using Docker Compose
docker compose build

# Load locally built images directly into Kind control-plane
kind load docker-image deployx-backend:latest --name deployx
kind load docker-image deployx-frontend:latest --name deployx
```

### 2. Validate and Apply Manifests

```bash
# Perform client-side dry-run validation
kubectl apply --dry-run=client -f infrastructure/kubernetes/

# Apply manifests to the Kind cluster
kubectl apply -f infrastructure/kubernetes/
```

### 3. Verify Deployment and Pod Status

```bash
# Check all resources and endpoints in the deployx namespace
kubectl get all,endpoints -n deployx
```

Expected output:
```text
NAME                                         READY   STATUS    RESTARTS   AGE
pod/deployx-backend-56f8f87766-26sbl         1/1     Running   0          45m
pod/deployx-backend-green-545c9c9966-9wz7j   1/1     Running   0          45m
pod/deployx-frontend-78c6597557-45jkm        1/1     Running   6          2h

NAME                       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
service/backend            ClusterIP   10.96.127.17    <none>        8000/TCP       119m
service/deployx-backend    ClusterIP   10.96.119.136   <none>        8000/TCP       2h
service/deployx-frontend   NodePort    10.96.115.16    <none>        80:30080/TCP   2h

NAME                                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/deployx-backend          1/1     1            1           45m
deployment.apps/deployx-backend-green    1/1     1            1           45m
deployment.apps/deployx-frontend         1/1     1            1           2h

NAME                         ENDPOINTS         AGE
endpoints/backend            10.244.0.8:8000   119m
endpoints/deployx-backend    10.244.0.8:8000   2h
endpoints/deployx-frontend   10.244.0.6:80     2h
```

### 4. Test Live Endpoints via Port-Forward

```bash
# Start port-forwarding to local port 8080
kubectl port-forward -n deployx svc/deployx-frontend 8080:80

# In a separate terminal, test the proxied endpoints:
# 1. Frontend Web Dashboard
curl -I http://localhost:8080/

# 2. Liveness Probe (proxied through active Blue/Green backend)
curl -i http://localhost:8080/health/live

# 3. Application System Status
curl -i http://localhost:8080/api/v1/status

# 4. Prometheus Metrics
curl -s http://localhost:8080/metrics | grep deployx_http_requests_total
```

---

## Operational Notes & Troubleshooting

### Deployment Selector Immutability
In Kubernetes, `spec.selector` on Deployments is immutable after creation. When introducing label `deployment-color: blue` to an existing deployment without recreation, Kubernetes rejects the mutation. To apply:
```bash
kubectl delete deployment -n deployx deployx-backend
kubectl apply -f infrastructure/kubernetes/backend.yaml
```

### Frontend DNS Resolution
During initial deployment, the frontend pod requires the `backend` Service to exist so Nginx can resolve `http://backend:8000` during initialization. Applying `backend-alias.yaml` provides this DNS record.

### Scope and Future Milestones
- **Phase 5 (Completed):** Blue-Green Deployments, selector switching on `backend` Service, and `switch_traffic.sh` controller with pre-flight checks and automated rollback.
- **Phase 6 (Up Next):** Centralized Prometheus scrape server and Grafana dashboards for cluster and telemetry monitoring.
- **ConfigMaps / Secrets:** Configuration externalization via ConfigMap (`deployx-config`) and Secret templates is planned for upcoming phases.
