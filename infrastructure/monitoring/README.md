# DeployX — Prometheus & Grafana Monitoring Architecture

## Overview

Phase 6 implements a lightweight, enterprise-grade observability stack for DeployX inside the `deployx` Kubernetes namespace on the local Kind cluster. The architecture comprises a dedicated **Prometheus** server scraping active backend telemetry and self-metrics, automated alert rule evaluations, and a provisioned **Grafana** instance featuring the "DeployX — Operations & Telemetry Overview" dashboard.

The entire monitoring tier is engineered to respect strict memory constraints ($\le 384\text{ MiB}$ for Prometheus, $\le 192\text{ MiB}$ for Grafana) to operate reliably in resource-conscious local WSL2 environments without requiring heavy operators or external dependencies.

---

## Architecture & Scrape Topology

```text
+---------------------------------------------------------------------------------------------------+
| Kubernetes Cluster: deployx (Kind v1.34.0) | Namespace: deployx                                    |
|                                                                                                   |
|   +-------------------------------------------------------------------------------------------+   |
|   | External Access via Port-Forwarding                                                       |   |
|   | Prometheus: localhost:9090  <--  kubectl port-forward svc/prometheus 9090:9090           |   |
|   | Grafana:    localhost:3001  <--  kubectl port-forward svc/grafana 3001:3000              |   |
|   +-----------------------------+-----------------------------+-------------------------------+   |
|                                 |                             |                                   |
|                                 v                             v                                   |
|   +---------------------------------------+         +-----------------------------------------+   |
|   | Service: prometheus (ClusterIP :9090) |         | Service: grafana (ClusterIP :3000)      |   |
|   +-------------------+-------------------+         +-------------------+---------------------+   |
|                       |                                                 |                         |
|                       v                                                 v                         |
|   +---------------------------------------+  Proxy  +-----------------------------------------+   |
|   | Pod: deployx-prometheus               | <====== | Pod: deployx-grafana                    |   |
|   | Image: prom/prometheus:v2.54.1        | Queries | Image: grafana/grafana:11.2.0           |   |
|   | Limits: 250m CPU, 384Mi RAM           |         | Limits: 200m CPU, 192Mi RAM             |   |
|   | Retention: 24h / 128MB TSDB           |         | Datasource: http://prometheus:9090      |   |
|   | Alerting: TargetDown, High5xx, Latency|         | Dashboard: DeployX Overview (8 panels)  |   |
|   +-------------------+-------------------+         +-----------------------------------------+   |
|                       |                                                                           |
|                       | 15s Scrape Interval (HTTP GET /metrics)                                   |
|                       v                                                                           |
|   +-------------------------------------------------------------------------------------------+   |
|   | Service: backend (Active Blue-Green Router, Port 8000)                                    |   |
|   | Dynamic Selector: app=deployx-backend, deployment-color=[blue|green]                      |   |
|   +---------------------------------------------+---------------------------------------------+   |
|                                                 |                                                 |
|                    +----------------------------+----------------------------+                    |
|                    | (Active Selector: blue)                                 | (Active: green)    |
|                    v                                                         v                    |
|   +-----------------------------------+                     +---------------------------------+   |
|   | Pod: deployx-backend (Blue)       |                     | Pod: deployx-backend-green      |   |
|   | Exposes: /metrics (Prometheus)    |                     | Exposes: /metrics (Prometheus)  |   |
|   +-----------------------------------+                     +---------------------------------+   |
+---------------------------------------------------------------------------------------------------+
```

---

## Monitoring Components

### 1. Prometheus Server (`infrastructure/monitoring/prometheus.yaml`)
- **Deployment:** `deployx-prometheus` (1 replica, image `prom/prometheus:v2.54.1`).
- **Services:** `prometheus` and `deployx-prometheus` (ClusterIP, Port 9090 $\rightarrow$ TargetPort `http-web` 9090).
- **Resource Discipline:**
  - Requests: CPU `50m`, Memory `128Mi`
  - Limits: CPU `250m`, Memory `384Mi` (strictly capped at $\le 384\text{ MiB}$).
- **Security Context:** Non-root execution (`runAsUser: 65534`, `runAsGroup: 65534`, `fsGroup: 65534`).
- **Scrape Targets:**
  - `deployx-backend`: Scrapes `backend.deployx.svc.cluster.local:8000/metrics` every 15 seconds. Scrapes whichever deployment (Blue or Green) is currently routed by the `backend` Service.
  - `prometheus`: Scrapes internal Prometheus metrics at `localhost:9090` every 15 seconds.
- **Alert Rules (`alerts.yml`):**
  - `DeployXBackendDown`: Triggers if `up{job="deployx-backend"} == 0` for 30 seconds (Severity: `critical`).
  - `DeployXHighErrorRate`: Triggers if HTTP 5xx error percentage exceeds 5% of total traffic over a 2-minute window (Severity: `warning`).
  - `DeployXHighRequestLatency`: Triggers if p95 request duration exceeds 500ms over 2 minutes (Severity: `warning`).

### 2. Grafana Dashboard & Provisioning (`infrastructure/monitoring/grafana.yaml`)
- **Deployment:** `deployx-grafana` (1 replica, image `grafana/grafana:11.2.0`).
- **Services:** `grafana` and `deployx-grafana` (ClusterIP, Port 3000 $\rightarrow$ TargetPort `http-grafana` 3000).
- **Resource Discipline:**
  - Requests: CPU `50m`, Memory `64Mi`
  - Limits: CPU `200m`, Memory `192Mi` (strictly capped at $\le 192\text{ MiB}$).
- **Security & Credentials:**
  - Admin credentials stored securely in Kubernetes Secret `deployx-grafana-secret` (`admin-user`, `admin-password`).
  - Non-root execution (`runAsUser: 472`, `runAsGroup: 472`, `fsGroup: 472`).
  - Anonymous viewer access enabled (`GF_AUTH_ANONYMOUS_ENABLED: "true"`, `Viewer` role) for dashboard viewing, while admin management remains protected by secret credentials.
- **Automated Provisioning:**
  - **Datasource:** ConfigMap `deployx-grafana-datasources` provisions Prometheus (`http://prometheus.deployx.svc.cluster.local:9090`) as the default datasource.
  - **Dashboard Provider:** ConfigMap `deployx-grafana-dashboard-provider` mounts dashboards from `/var/lib/grafana/dashboards`.
  - **Dashboard JSON:** ConfigMap `deployx-grafana-dashboards` embeds `deployx-overview.json`.
- **Dashboard Panels ("DeployX — Operations & Telemetry Overview"):**
  1. **Backend Target Status (Stat):** Live health (`HEALTHY` / `DOWN`) mapped from `up{job="deployx-backend"}`.
  2. **Application Uptime (Stat):** Real-time uptime formatted in seconds/hours from `deployx_application_uptime_seconds`.
  3. **HTTP 5xx Error Rate (Stat):** Instantaneous error percentage with green/orange/red threshold bounds.
  4. **Current Throughput (Stat):** Total requests per second handled by backend.
  5. **Application Release Info (Stat):** Displays version, environment, and application name from `deployx_application_info`.
  6. **HTTP Request Rate by Endpoint (Timeseries):** Real-time per-handler traffic breakdown.
  7. **HTTP Request Rate by Status Code (Timeseries):** Per-status code throughput (200, 404, 500).
  8. **Request Latency Percentiles (Timeseries):** p50 median, p95 SLO, and p99 worst-case latencies.

---

## Deployment & Verification Workflow

### 1. Deploy the Monitoring Stack
Execute the automated deployment script:
```bash
./scripts/linux/deploy_monitoring.sh
```

Or apply the manifests manually:
```bash
kubectl apply -f infrastructure/monitoring/prometheus.yaml
kubectl apply -f infrastructure/monitoring/grafana.yaml

kubectl rollout status deployment/deployx-prometheus -n deployx --timeout=60s
kubectl rollout status deployment/deployx-grafana -n deployx --timeout=60s
```

### 2. Verify Pod and Service Status
```bash
kubectl get pods,svc,endpoints -n deployx -l app.kubernetes.io/component=monitoring
```

Expected output:
```text
NAME                                      READY   STATUS    RESTARTS   AGE
pod/deployx-grafana-xxxx-xxxx             1/1     Running   0          2m
pod/deployx-prometheus-xxxx-xxxx          1/1     Running   0          2m

NAME                         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/deployx-grafana      ClusterIP   10.96.x.x       <none>        3000/TCP   2m
service/deployx-prometheus   ClusterIP   10.96.x.x       <none>        9090/TCP   2m
service/grafana              ClusterIP   10.96.x.x       <none>        3000/TCP   2m
service/prometheus           ClusterIP   10.96.x.x       <none>        9090/TCP   2m
```

### 3. Port-Forward and Access Monitoring

#### Prometheus UI & Targets
```bash
kubectl port-forward -n deployx svc/prometheus 9090:9090
```
- Web UI: [http://localhost:9090](http://localhost:9090)
- Targets Status: [http://localhost:9090/targets](http://localhost:9090/targets) (verify `deployx-backend` is `UP 1/1`)
- Alerts Status: [http://localhost:9090/alerts](http://localhost:9090/alerts)

#### Grafana Operations Dashboard
```bash
kubectl port-forward -n deployx svc/grafana 3001:3000
```
- Dashboard URL: [http://localhost:3001](http://localhost:3001)
- Direct Dashboard: [http://localhost:3001/d/deployx-overview](http://localhost:3001/d/deployx-overview)
- Default Login: Username: `admin`, Password: `deployx-admin-2026` (Anonymous viewing enabled by default).
