# DeployX Frontend – Cloud Operations Center

## 1. Overview
The DeployX Frontend is a high-performance, dark-themed DevOps operations dashboard designed for real-time application health monitoring, Prometheus RED metrics visualization, and deployment observability. Engineered with pure HTML5, CSS3, and modern Vanilla ES6+ JavaScript, it delivers a rich interactive experience with zero Node.js build overhead, respecting the ~3.5 GiB host RAM budget.

---

## 2. Architecture & File Structure

```text
frontend/
├── index.html              # Semantic HTML5 layout, accessible sections & responsive sidebar
├── css/
│   └── styles.css          # Dark-mode theme, CSS variables, responsive grid & animations
├── js/
│   ├── api.js              # Centralized API fetcher, timeout/abort controller & Prometheus text parser
│   ├── charts.js           # Chart.js visualizer with pure CSS/DOM fallback for air-gapped setups
│   └── dashboard.js        # UI controller, safe DOM renderer (zero innerHTML), and 10s polling loop
├── assets/
│   └── favicon.svg         # Clean brand icon
└── README.md               # Architecture, setup instructions, and runbook
```

---

## 3. Key Design Principles & Security

1. **Zero Unsafe DOM Rendering:** All dynamic values and API payloads are injected strictly using `element.textContent`, `document.createTextNode`, or DOM creation methods (`document.createElement`). Untrusted data is never passed to `innerHTML`.
2. **Prometheus Exposition Parser:** Custom parser parses the standard Prometheus text format (`deployx_http_requests_total`, `deployx_http_request_duration_seconds`, `deployx_application_uptime_seconds`, `deployx_application_info`). Latency is calculated from `duration_sum / duration_count` rather than misinterpreting cumulative histogram buckets as independent observations.
3. **Resilient Network Handling:**
   - Automatic 10-second polling cycle.
   - Guard against overlapping network requests using an `isFetching` lock.
   - Configurable timeout (6000ms) with `AbortController`.
   - Distinct `OPERATIONAL`, `DEGRADED`, and `DISCONNECTED` states with diagnostic alert banners.
   - Automatic recovery when backend restarts.
4. **Honest Architectural States:**
   - Blue-Green Deployment is displayed as **NOT CONFIGURED** (scheduled for Phase 5).
   - Kubernetes Cluster is displayed as **NOT CONNECTED** (scheduled for Phase 4).
   - Disaster Recovery is displayed as **NOT CONFIGURED** (scheduled for Phase 5 & 9).
   - Zero fabricated or placeholder mock statistics.
5. **Offline Capability:**
   - If Chart.js CDN is blocked or unavailable, `charts.js` automatically renders semantic HTML/CSS progress bars.

---

## 4. Local Execution Guide

### Option A: Serve with Python Built-In Web Server (Recommended)
From the project root:
```bash
# Serve frontend on port 3000
python3 -m http.server 3000 --directory frontend
```
Then open your browser at:
`http://localhost:3000`

### Option B: Serve via FastAPI Backend Static Mount (Optional)
The backend can also serve these static assets directly.

---

## 5. Configuring the Backend API URL

By default, the dashboard points to:
`http://localhost:8000`

To customize the backend endpoint:
1. Use the **API:** input pill located in the top-right header of the dashboard.
2. Enter the target URL (e.g., `http://127.0.0.1:8000` or a remote IP).
3. The configuration is automatically validated and saved to `localStorage`.

---

## 6. Testing Backend Connectivity

1. Start the FastAPI backend:
   ```bash
   python3 -m uvicorn backend.app.main:app --host 0.0.0.0 --port 8000
   ```
2. Start the frontend web server:
   ```bash
   python3 -m http.server 3000 --directory frontend
   ```
3. Open `http://localhost:3000` in your web browser.
4. Verify:
   - Header badge indicates `OPERATIONAL` (green dot).
   - Liveness displays `ALIVE`.
   - Readiness displays `READY`.
   - App version displays `v1.0.0 [deployx-backend]`.
   - Total HTTP requests counter and endpoints table reflect real Prometheus metrics.
   - Click the **Refresh** button to verify instant polling.
   - Stop the backend (Ctrl+C); verify the dashboard shows `DISCONNECTED` with an alert banner.
   - Restart the backend; verify the dashboard recovers automatically on the next poll.

---

## 7. Current Limitations
- Blue-Green deployment and disaster recovery triggers are not yet automated (planned for Phase 5).
- Kubernetes pod replica and node metrics are not yet connected (planned for Phase 4).
