# DeployX — Container Architecture & Docker Orchestration

## Overview

DeployX utilizes a multi-container Docker architecture optimized for production reliability, minimal memory footprint (< 300 MB combined runtime), strict non-root security boundaries, and automated container health lifecycle tracking.

The orchestration topology consists of two cooperating services connected via an isolated Docker bridge network (`deployx-network`):

1. **`backend` (FastAPI Health & Telemetry Engine)**:
   - Base image: `python:3.14-slim`
   - Non-root user: `deployx:10001`
   - Port: `8000`
   - Native container healthcheck: `curl -f http://127.0.0.1:8000/health/live`
   - Serves liveness/readiness probes, system status, Prometheus exposition, and OpenAPI docs.

2. **`frontend` (Nginx Alpine Reverse Proxy & Static Dashboard)**:
   - Base image: `nginx:alpine`
   - Port: `80` (mapped to host port `3000`)
   - Native container healthcheck: `wget -q --spider http://127.0.0.1:80/`
   - Serves compiled static UI assets and transparently reverse-proxies `/health/`, `/api/`, `/metrics`, `/docs`, and `/openapi.json` to `http://backend:8000`.
   - Starts strictly after the backend is reported healthy (`condition: service_healthy`).

---

## Directory Layout

```
.
├── compose.yaml                # Canonical root Docker Compose specification
├── .dockerignore               # Root build context filter
├── backend/
│   ├── Dockerfile              # Hardened Python 3.14-slim container specification
│   ├── .dockerignore           # Backend build exclusions (caches, tests, .venv)
│   ├── requirements.txt        # Pinned runtime dependencies
│   └── app/                    # FastAPI application package
└── frontend/
    ├── Dockerfile              # Lightweight Nginx Alpine container specification
    ├── .dockerignore           # Frontend build exclusions (test scripts, node_modules)
    ├── nginx.conf              # Nginx reverse proxy & gzip configuration
    ├── index.html              # Cloud Operations Center dashboard
    ├── css/                    # Dark-mode responsive styles
    ├── js/                     # API client, Chart.js visualization, and dashboard controller
    └── assets/                 # Brand assets and SVG icons
```

---

## Quickstart & Lifecycle Commands

### 1. Build Container Images

```bash
docker compose build
```

Build arguments and context:
- `backend`: Built from `./backend` using `backend/Dockerfile` with Debian package index cleanup and pip cache suppression (`--no-cache-dir`).
- `frontend`: Built from `./frontend` using `frontend/Dockerfile` on Alpine Linux (< 25 MB).

### 2. Launch Services in Background

```bash
docker compose up -d
```

Compose initiates the `backend` first. The `frontend` evaluates the backend healthcheck (`condition: service_healthy`) and begins listening once the backend is operational.

### 3. Verify Container Status & Health

```bash
docker compose ps
```

Expected output:
```
NAME               IMAGE                     COMMAND                  SERVICE    CREATED          STATUS                    PORTS
deployx-backend    deployx-backend:latest    "python -m uvicorn b…"   backend    10 seconds ago   Up 9 seconds (healthy)    0.0.0.0:8000->8000/tcp
deployx-frontend   deployx-frontend:latest   "nginx -g 'daemon of…"   frontend   5 seconds ago    Up 4 seconds (healthy)    0.0.0.0:3000->80/tcp
```

### 4. Inspect Live Logs

```bash
# Follow logs for both services
docker compose logs -f

# Follow backend logs specifically
docker compose logs -f backend

# Follow frontend access & error logs
docker compose logs -f frontend
```

### 5. Validate HTTP & Telemetry Endpoints

All application routes can be accessed through the frontend Nginx reverse proxy on port 3000:

```bash
# Frontend HTML
curl -I http://localhost:3000/

# Proxied Liveness Probe
curl -i http://localhost:3000/health/live

# Proxied Readiness Probe
curl -i http://localhost:3000/health/ready

# Proxied Application Status API
curl -i http://localhost:3000/api/v1/status

# Proxied Prometheus Metrics
curl -s http://localhost:3000/metrics | grep deployx

# Proxied Interactive API Docs
curl -I http://localhost:3000/docs
```

Direct access to the backend ASGI server on port 8000 remains available for diagnostics:

```bash
curl -i http://localhost:8000/health/live
```

### 6. Stop and Clean Up Services

```bash
# Stop containers and remove Compose bridge network
docker compose down

# Stop containers and delete associated volumes if needed
docker compose down -v
```

---

## Reverse Proxy & API Routing Behavior

In standalone development (e.g. running `python3 -m http.server 3000`), the dashboard uses cross-origin calls to `http://localhost:8000`.

In Docker containerization:
1. The browser visits `http://localhost:3000/`.
2. All API telemetry requests in `frontend/js/api.js` use **same-origin relative URLs** (`/health/live`, `/api/v1/status`, `/metrics`).
3. Nginx intercepts these paths and proxies them internally across the `deployx-network` to `http://backend:8000`.
4. If a developer runs the frontend outside Docker without Nginx, `frontend/js/api.js` automatically detects 404 responses from the same origin and seamlessly falls back to `http://localhost:8000`.

---

## Security & Resource Hardening

1. **Least-Privilege Non-Root Execution**:
   - Backend runs as system user `deployx` (`UID 10001`, `GID 10001`).
   - Root privileges are discarded before starting Uvicorn.
2. **Build Context Sanitization**:
   - `.dockerignore` files eliminate unnecessary files, logs, virtual environments (`.venv`), and test caches from Docker image layers.
3. **Cache Invalidation & Freshness**:
   - Reverse-proxied telemetry headers include `Cache-Control: no-store, no-cache, must-revalidate, max-age=0` to ensure real-time accuracy in monitoring systems.
4. **Minimal Memory Budget**:
   - Under standard load, `deployx-backend` consumes ~65 MiB RAM and `deployx-frontend` consumes ~12 MiB RAM, well within the 3.5 GiB WSL2 host constraint.
