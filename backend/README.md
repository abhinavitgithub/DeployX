# DeployX Backend – Health & Telemetry Engine

## 1. Overview
The DeployX Backend is a high-performance, lightweight FastAPI service engineered for application health monitoring, liveness/readiness orchestration, RED metrics export, and structured request correlation.

---

## 2. Architecture & Directory Taxonomy

```text
backend/
├── app/
│   ├── __init__.py
│   ├── main.py                     # FastAPI factory, lifespan, CORS & root endpoint
│   ├── config.py                   # Pydantic Settings & environment variables
│   ├── logging_config.py           # Structured JSON logger & ContextVar correlation ID
│   ├── middleware/
│   │   ├── __init__.py
│   │   └── request_metrics.py      # X-Request-ID validation, latency timing, bounded labels
│   ├── api/
│   │   ├── __init__.py
│   │   └── routes/
│   │       ├── __init__.py
│   │       ├── health.py           # /health/live & /health/ready probes
│   │       ├── status.py           # /api/v1/status sanitized system metadata
│   │       └── metrics.py          # /metrics Prometheus exposition
│   └── services/
│       ├── __init__.py
│       ├── metrics.py              # Prometheus metric definitions & bounded tracking
│       └── state.py                # Runtime uptime & readiness state manager
├── tests/
│   ├── __init__.py
│   ├── conftest.py                 # Pytest fixtures & TestClient configuration
│   ├── test_health.py              # Liveness & readiness probe tests
│   ├── test_status.py              # System status & security leak tests
│   ├── test_metrics.py             # Prometheus metrics formatting & self-exclusion tests
│   └── test_middleware.py          # Correlation ID sanitization & 500 handler tests
├── verify_endpoints.py             # Live HTTP subprocess verification harness
├── requirements.txt                # Pinned dependency releases
└── README.md
```

---

## 3. API Endpoints Reference

| Method | Path | Purpose | Authentication | Status Code |
|---|---|---|---|---|
| `GET` | `/` | Service root & API docs link | None | `200 OK` |
| `GET` | `/health/live` | Process liveness probe | None | `200 OK` |
| `GET` | `/health/ready` | Process readiness probe | None | `200 OK` / `503 Unavailable` |
| `GET` | `/api/v1/status` | Sanitized system status & uptime | None | `200 OK` |
| `GET` | `/metrics` | Prometheus metrics exposition | None | `200 OK` |
| `GET` | `/docs` | Interactive Swagger API documentation | None | `200 OK` |

---

## 4. Dependencies

Tested and pinned on Python 3.14.4:
- `fastapi==0.162.0`
- `uvicorn==0.54.0`
- `pydantic-settings==2.16.2`
- `prometheus-client==0.26.0`
- `httpx==0.28.1`
- `pytest==9.2.0`
- `ruff==0.17.3`

---

## 5. Local Setup & Execution Guide

### 5.1 Activate Virtual Environment
```bash
# In the project root (/home/abhinav2004/projects/deployx)
source .venv/bin/activate
```

### 5.2 Start the Backend with Uvicorn
```bash
python3 -m uvicorn backend.app.main:app --host 0.0.0.0 --port 8000 --log-level info
```

### 5.3 Live Verification Harness
Run the end-to-end live verification script:
```bash
python3 backend/verify_endpoints.py
```

### 5.4 Manual Curl Verification
```bash
# Root Information
curl -i http://localhost:8000/

# Liveness Probe
curl -i http://localhost:8000/health/live

# Readiness Probe
curl -i http://localhost:8000/health/ready

# Application Status
curl -i http://localhost:8000/api/v1/status

# Custom Request Correlation ID
curl -i -H "X-Request-ID: my-custom-trace-id" http://localhost:8000/api/v1/status

# Prometheus Metrics
curl -s http://localhost:8000/metrics | grep deployx_
```

---

## 6. Testing & Quality Assurance Results

### 6.1 Ruff Linter
```bash
ruff check backend/
```
**Result:** `All checks passed!` (0 lint errors).

### 6.2 Pytest Execution
```bash
pytest -v backend/tests/
```
**Result:** **20 passed, 0 failed** in 0.51s.
- `test_root_endpoint_returns_metadata`: PASSED
- `test_liveness_probe_returns_200_and_alive`: PASSED
- `test_readiness_probe_returns_200_when_ready`: PASSED
- `test_readiness_probe_returns_503_when_not_ready`: PASSED
- `test_metrics_endpoint_returns_prometheus_format`: PASSED
- `test_metrics_contains_all_required_metrics`: PASSED
- `test_metrics_endpoint_excludes_self_from_request_metrics`: PASSED
- `test_request_count_metrics_increment_on_traffic`: PASSED
- `test_application_info_contains_configured_metadata`: PASSED
- `test_request_id_generated_when_omitted`: PASSED
- `test_request_id_preserved_when_valid`: PASSED
- `test_request_id_replaced_when_malformed`: PASSED
- `test_request_id_replaced_when_excessively_long`: PASSED
- `test_invalid_routes_return_404_with_request_id`: PASSED
- `test_unmatched_route_metrics_uses_bounded_label`: PASSED
- `test_unhandled_exception_returns_500_with_correlation_id`: PASSED
- `test_status_endpoint_returns_expected_fields`: PASSED
- `test_status_uptime_increases`: PASSED
- `test_status_endpoint_never_exposes_secrets`: PASSED
- `test_status_reflects_readiness_state_change`: PASSED

---

## 7. Known Limitations & Architectural Notes
- The initial service has no mandatory external database or cache dependencies; readiness defaults to `ready`.
- Kubernetes deployment manifests and blue-green cutover scripts are scheduled for subsequent phases.
