"""DeployX Real Live HTTP API Verification Script.

Starts the Uvicorn server in a subprocess, issues real HTTP requests
against all Phase 1 endpoints, and verifies response headers, payloads,
and Prometheus metrics.
"""

import subprocess
import sys
import time
from datetime import datetime

import httpx

BASE_URL = "http://127.0.0.1:8000"


def main() -> int:
    """Run end-to-end live endpoint verification."""
    print("=" * 60)
    print(" DeployX Phase 1 - Live HTTP API Verification ")
    print("=" * 60)

    # Start Uvicorn in subprocess
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "backend.app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            "8000",
            "--log-level",
            "info",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    try:
        # Wait up to 10 seconds for server to be responsive
        server_ready = False
        with httpx.Client(base_url=BASE_URL, timeout=3.0) as client:
            for attempt in range(1, 20):
                try:
                    res = client.get("/health/live")
                    if res.status_code == 200:
                        server_ready = True
                        print(f"[OK] Server is UP and responsive on attempt {attempt}")
                        break
                except httpx.ConnectError:
                    time.sleep(0.5)

            if not server_ready:
                print("[ERROR] Server failed to start within timeout.")
                return 1

            # 1. Root Endpoint GET /
            print("\n--- 1. Testing GET / ---")
            res_root = client.get("/")
            print(f"Status: {res_root.status_code}")
            print(f"Headers: X-Request-ID={res_root.headers.get('X-Request-ID')}")
            print(f"Payload: {res_root.json()}")
            assert res_root.status_code == 200
            assert res_root.json()["app_name"] == "deployx-backend"
            assert "X-Request-ID" in res_root.headers

            # 2. Docs Endpoint GET /docs
            print("\n--- 2. Testing GET /docs ---")
            res_docs = client.get("/docs")
            print(f"Status: {res_docs.status_code}")
            print(f"Headers: Content-Type={res_docs.headers.get('content-type')}")
            assert res_docs.status_code == 200
            assert "text/html" in res_docs.headers.get("content-type", "")

            # 3. Liveness Probe GET /health/live
            print("\n--- 3. Testing GET /health/live ---")
            res_live = client.get("/health/live")
            print(f"Status: {res_live.status_code}")
            print(f"Payload: {res_live.json()}")
            assert res_live.status_code == 200
            assert res_live.json()["status"] == "alive"
            datetime.fromisoformat(res_live.json()["timestamp"])

            # 4. Readiness Probe GET /health/ready
            print("\n--- 4. Testing GET /health/ready ---")
            res_ready = client.get("/health/ready")
            print(f"Status: {res_ready.status_code}")
            print(f"Payload: {res_ready.json()}")
            assert res_ready.status_code == 200
            assert res_ready.json()["status"] == "ready"
            assert res_ready.json()["checks"]["system"] == "ok"

            # 5. Application Status GET /api/v1/status
            print("\n--- 5. Testing GET /api/v1/status ---")
            res_status = client.get("/api/v1/status")
            print(f"Status: {res_status.status_code}")
            print(f"Payload: {res_status.json()}")
            assert res_status.status_code == 200
            status_data = res_status.json()
            assert status_data["app_name"] == "deployx-backend"
            assert status_data["process_status"] == "running"
            assert status_data["readiness_status"] == "ready"
            assert status_data["uptime_seconds"] >= 0.0

            # 6. Incoming Custom X-Request-ID Header
            print("\n--- 6. Testing Custom X-Request-ID Preservation ---")
            custom_req_id = "deployx-live-verify-9900"
            res_custom = client.get(
                "/api/v1/status", headers={"X-Request-ID": custom_req_id}
            )
            print(f"Status: {res_custom.status_code}")
            print(f"Echoed X-Request-ID: {res_custom.headers.get('X-Request-ID')}")
            assert res_custom.headers.get("X-Request-ID") == custom_req_id

            # 7. Prometheus Metrics GET /metrics
            print("\n--- 7. Testing GET /metrics ---")
            res_metrics = client.get("/metrics")
            print(f"Status: {res_metrics.status_code}")
            metric_lines = [
                line
                for line in res_metrics.text.splitlines()
                if line.startswith("deployx_") and not line.startswith("deployx_http_request_duration_seconds_bucket")
            ]
            for line in metric_lines[:15]:
                print(f"Metric: {line}")
            assert res_metrics.status_code == 200
            assert "deployx_http_requests_total" in res_metrics.text
            assert "deployx_http_request_duration_seconds" in res_metrics.text
            assert "deployx_application_uptime_seconds" in res_metrics.text
            assert "deployx_application_info" in res_metrics.text
            assert 'handler="/metrics"' not in res_metrics.text

            print("\n[SUCCESS] ALL LIVE HTTP ENDPOINTS VALIDATED SUCCESSFULLY!")
            return 0

    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
        print("[INFO] Uvicorn test server stopped cleanly.")


if __name__ == "__main__":
    sys.exit(main())
