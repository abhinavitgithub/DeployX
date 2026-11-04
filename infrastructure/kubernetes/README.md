# DeployX — Kubernetes Deployment & Kind Architecture

## Overview

Phase 4 introduces declarative Kubernetes manifests to deploy DeployX onto a local **Kind** (Kubernetes in Docker) cluster (`deployx`). The deployment orchestrates the FastAPI health telemetry backend and the Nginx frontend reverse proxy inside an isolated namespace (`deployx`), utilizing container health probes, strict resource limits, and internal ClusterIP service discovery.

---

## Architecture & Cluster Topology

```
+-----------------------------------------------------------------------------------------+
| Kind Cluster: deployx (v1.34.0)                                                         |
| Namespace: deployx                                                                      |
|                                                                                         |
|   +---------------------------------------------------------------------------------+   |
|   | External Access / Host Port Mapping                                            |   |
|   | NodePort: 30080  |  kubectl port-forward svc/deployx-frontend 8080:80           |   |
|   +---------------------------------------+-----------------------------------------+   |
|                                           |                                             |
|                                           v                                             |
|   +---------------------------------------------------------------------------------+   |
|   | Service: deployx-frontend (NodePort: 80 -> NodePort 30080)                     |   |
|   | Selector: app: deployx-frontend                                                |   |
|   | Endpoint: 10.244.0.6:80                                                         |   |
|   +---------------------------------------+-----------------------------------------+   |
|                                           |                                             |
|                                           v                                             |
|   +---------------------------------------------------------------------------------+   |
|   | Pod: deployx-frontend-xxxx (1/1 Running)                                        |   |
|   | Container: frontend (nginx:alpine)                                             |   |
|   | Serves: Static dashboard assets (HTML, CSS, JS)                                |   |
|   | Proxies: /health/, /api/, /metrics, /docs to upstream 'http://backend:8000'    |   |
|   +---------------------------------------+-----------------------------------------+   |
|                                           |                                             |
|                         Upstream Internal Service Routing                               |
|                     (DNS resolution for hostname 'backend')                             |
|                                           |                                             |
|               +---------------------------+---------------------------+                 |
|               |                                                       |                 |
|               v                                                       v                 |
|   +-----------------------------+         +-------------------------------------+       |
|   | Service: backend            |         | Service: deployx-backend            |       |
|   | Type: ClusterIP (Port 8000) |         | Type: ClusterIP (Port 8000)         |       |
|   | Selector: app=deployx-back. |         | Selector: app=deployx-back.         |       |
|   | (Docker Compose DNS Alias)  |         | (Canonical Kubernetes Service)      |       |
|   +--------------+--------------+         +------------------+------------------+       |
|                  |                                           |                          |
|                  +---------------------+---------------------+                          |
|                                        |                                                |
|                                        v                                                |
|   +---------------------------------------------------------------------------------+   |
|   | Pod: deployx-backend-xxxx (1/1 Running)                                         |   |
|   | Container: backend (python:3.14-slim)                                           |   |
|   | Endpoint: 10.244.0.5:8000                                                       |   |
|   | Exposes: /health/live, /health/ready, /api/v1/status, /metrics, /docs          |   |
|   +---------------------------------------------------------------------------------+   |
+-----------------------------------------------------------------------------------------+
```

---

## Manifest Specifications

All manifests are located in `infrastructure/kubernetes/`:

```
infrastructure/kubernetes/
├── namespace.yaml          # Dedicated 'deployx' namespace
├── backend.yaml            # Backend Deployment (1 replica) + ClusterIP Service (deployx-backend)
├── backend-alias.yaml      # ClusterIP Service alias ('backend') for Nginx upstream compatibility
└── frontend.yaml           # Frontend Deployment (1 replica) + NodePort Service (deployx-frontend)
```

### 1. Namespace (`namespace.yaml`)
- **Name:** `deployx`
- **Labels:** `app.kubernetes.io/part-of: deployx`

### 2. Backend Deployment & Service (`backend.yaml`)
- **Deployment Name:** `deployx-backend`
- **Replicas:** 1
- **Image:** `deployx-backend:latest` (`imagePullPolicy: IfNotPresent`)
- **Container Port:** 8000 (`http`)
- **Probes:**
  - **Readiness:** HTTP GET `/health/ready` on port `http` (initial delay: 5s, period: 10s)
  - **Liveness:** HTTP GET `/health/live` on port `http` (initial delay: 10s, period: 20s)
- **Resource Constraints:**
  - **Requests:** CPU `100m`, Memory `128Mi`
  - **Limits:** CPU `500m`, Memory `384Mi`
- **Primary Service:** `deployx-backend` (ClusterIP, Port `8000` $\rightarrow$ TargetPort `8000`)

### 3. Backend DNS Alias Service (`backend-alias.yaml`)
- **Service Name:** `backend`
- **Type:** `ClusterIP`
- **Port:** `8000` $\rightarrow$ TargetPort `8000`
- **Selector:** `app: deployx-backend`
- **Architectural Rationale:** The frontend Nginx reverse proxy configuration (`frontend/nginx.conf`) routes requests to `http://backend:8000`, matching Docker Compose service discovery. Adding the `backend` ClusterIP service provides CoreDNS resolution for the `backend` hostname within the `deployx` namespace without requiring changes to Nginx or container image rebuilds.

### 4. Frontend Deployment & Service (`frontend.yaml`)
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

## Deployment & Verification Workflow

### 1. Build and Load Images into Kind

Kind runs its own container runtime and cannot access images on the host Docker daemon unless they are preloaded:

```bash
# Build images using Docker Compose or Docker CLI
docker compose build

# Load locally built images directly into the Kind cluster control-plane node
kind load docker-image deployx-backend:latest --name deployx
kind load docker-image deployx-frontend:latest --name deployx
```

### 2. Validate and Apply Manifests

```bash
# Perform client-side dry-run validation
kubectl apply --dry-run=client -f infrastructure/kubernetes/

# Apply manifests to the Kind cluster
kubectl apply -f infrastructure/kubernetes/namespace.yaml
kubectl apply -f infrastructure/kubernetes/backend.yaml
kubectl apply -f infrastructure/kubernetes/backend-alias.yaml
kubectl apply -f infrastructure/kubernetes/frontend.yaml
```

### 3. Verify Deployment and Pod Status

```bash
# Check all resources and endpoints in the deployx namespace
kubectl get all,endpoints -n deployx
```

Expected output:
```
NAME                                    READY   STATUS    RESTARTS   AGE
pod/deployx-backend-74c6ff475d-q4plr    1/1     Running   0          16m
pod/deployx-frontend-78c6597557-45jkm   1/1     Running   6          14m

NAME                       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
service/backend            ClusterIP   10.96.127.17    <none>        8000/TCP       8m43s
service/deployx-backend    ClusterIP   10.96.119.136   <none>        8000/TCP       16m
service/deployx-frontend   NodePort    10.96.115.16    <none>        80:30080/TCP   14m

NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/deployx-backend    1/1     1            1           16m
deployment.apps/deployx-frontend   1/1     1            1           14m

NAME                         ENDPOINTS         AGE
endpoints/backend            10.244.0.5:8000   8m43s
endpoints/deployx-backend    10.244.0.5:8000   16m
endpoints/deployx-frontend   10.244.0.6:80     14m
```

### 4. Test Live Endpoints via Port-Forward

Port-forwarding the `deployx-frontend` service forwards traffic through Nginx to the backend:

```bash
# Start port-forwarding to local port 8080
kubectl port-forward -n deployx svc/deployx-frontend 8080:80

# In a separate terminal, test the proxied endpoints:

# 1. Frontend Web Dashboard
curl -I http://localhost:8080/

# 2. Liveness Probe (proxied to backend)
curl -i http://localhost:8080/health/live

# 3. Application System Status (proxied to backend)
curl -i http://localhost:8080/api/v1/status

# 4. Prometheus Metrics (proxied to backend)
curl -s http://localhost:8080/metrics | grep deployx_http_requests_total
```

---

## Operational Notes & Troubleshooting

### Frontend Restart Analysis (Historical Restarts = 6)
During initial deployment, the `deployx-frontend` pod logged 6 restarts before reaching a steady state:
- **Root Cause:** Nginx attempts to resolve upstream hosts defined in `proxy_pass` directives (`http://backend:8000`) during initialization. Prior to applying `backend-alias.yaml`, the only service targeting the backend was named `deployx-backend`. CoreDNS returned `NXDOMAIN` for hostname `backend`, causing Nginx to terminate with exit code 1.
- **Resolution:** Applying `backend-alias.yaml` established the `backend` ClusterIP service. Once CoreDNS resolved `backend.deployx.svc.cluster.local`, the frontend pod started cleanly and has remained continuously `Running` and `Ready` (1/1).

### Scope and Future Milestones
- **ConfigMaps / Secrets:** Application runtime currently utilizes defaults. Configuration externalization via ConfigMap (`deployx-config`) and Secret templates is planned for subsequent phases.
- **Blue-Green Deployment:** Dynamic traffic switching between Blue and Green replicasets is scheduled for **Phase 5**.
- **Autoscaling & Ingress:** Horizontal Pod Autoscaler (HPA) and Ingress controller routing are not currently enabled; local access is verified via NodePort (`30080`) and `kubectl port-forward`.
