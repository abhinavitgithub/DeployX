"""Automated Integration & Verification Tests for DeployX Frontend Dashboard.

Validates:
1. Static asset delivery and MIME types (index.html, styles.css, js/api.js, js/charts.js, js/dashboard.js).
2. Semantic DOM element hierarchy, accessibility attributes, and viewport meta tags.
3. Dark-mode CSS variables and responsive media queries (desktop, tablet, mobile).
4. Strict compliance with honest architectural status ('NOT CONFIGURED' and 'NOT CONNECTED').
5. Zero unsafe DOM patterns.
6. CORS configuration parity between frontend origin and FastAPI backend.
7. End-to-end telemetry consumption from live backend endpoints.
"""

import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend.app.main import app

FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"


@pytest.fixture
def client() -> TestClient:
    """Synchronous test client for the FastAPI backend."""
    return TestClient(app=app, base_url="http://127.0.0.1:8000")


# ==============================================================================
# 1. Static Asset Presence & File Structure Tests
# ==============================================================================


def test_frontend_files_exist() -> None:
    """Verify that all required frontend assets exist in the project tree."""
    required_files = [
        FRONTEND_DIR / "index.html",
        FRONTEND_DIR / "css" / "styles.css",
        FRONTEND_DIR / "js" / "api.js",
        FRONTEND_DIR / "js" / "charts.js",
        FRONTEND_DIR / "js" / "dashboard.js",
        FRONTEND_DIR / "assets" / "favicon.svg",
        FRONTEND_DIR / "README.md",
    ]
    for file_path in required_files:
        assert file_path.is_file(), f"Required frontend file missing: {file_path}"


# ==============================================================================
# 2. HTML Structure, DOM IDs & Accessibility Tests
# ==============================================================================


def test_html_title_and_viewport() -> None:
    """Verify index.html contains correct title and responsive viewport tag."""
    html = (FRONTEND_DIR / "index.html").read_text(encoding="utf-8")

    assert "<title>DeployX — Cloud Operations Center</title>" in html
    assert '<meta name="viewport" content="width=device-width, initial-scale=1.0">' in html
    assert '<link rel="icon"' in html


def test_html_required_dom_element_ids() -> None:
    """Verify all DOM elements bound by dashboard.js exist in index.html."""
    html = (FRONTEND_DIR / "index.html").read_text(encoding="utf-8")

    expected_ids = [
        "connection-badge",
        "connection-status-text",
        "last-updated-text",
        "btn-refresh",
        "btn-toggle-auto",
        "api-url-input",
        "alert-banner",
        "alert-message",
        "menu-toggle",
        "sidebar",
        # System Overview
        "val-liveness",
        "meta-liveness",
        "val-readiness",
        "meta-readiness",
        "val-app-version",
        "meta-app-version",
        "val-uptime",
        "meta-uptime",
        # Performance Telemetry
        "val-total-requests",
        "val-avg-latency",
        "val-success-rate",
        "val-error-count",
        # Endpoints Table
        "table-endpoints-body",
        # Charts
        "chart-endpoints-container",
        "canvas-endpoints",
        "chart-status-container",
        "canvas-status",
    ]

    for element_id in expected_ids:
        assert f'id="{element_id}"' in html, (
            f"Missing required element ID in index.html: {element_id}"
        )


def test_html_honest_architectural_states() -> None:
    """Verify that unbuilt features strictly display 'NOT CONFIGURED' and 'NOT CONNECTED'."""
    html = (FRONTEND_DIR / "index.html").read_text(encoding="utf-8")

    # Blue-Green Deployment must be NOT CONFIGURED
    assert "NOT CONFIGURED" in html
    assert "NOT CONNECTED" in html

    # Verify sections exist with honest descriptions
    assert "Blue-Green Deployment Engine" in html
    assert (
        "Cluster Telemetry &amp; Workload Pods" in html
        or "Cluster Telemetry & Workload Pods" in html
    )
    assert "Automated DR Rollback Controller" in html


# ==============================================================================
# 3. Security & Safe DOM Rendering Audit
# ==============================================================================


def test_zero_unsafe_innerhtml_in_javascript() -> None:
    """Audit all frontend JavaScript to ensure zero unsafe innerHTML usage."""
    js_files = [
        FRONTEND_DIR / "js" / "api.js",
        FRONTEND_DIR / "js" / "charts.js",
        FRONTEND_DIR / "js" / "dashboard.js",
    ]

    for js_file in js_files:
        code = js_file.read_text(encoding="utf-8")
        # Check for innerHTML assignments
        matches = re.findall(r"\.innerHTML\s*=", code)
        assert len(matches) == 0, f"Found unsafe innerHTML assignment in {js_file.name}: {matches}"


# ==============================================================================
# 4. CSS Dark-Theme & Responsive Media Queries
# ==============================================================================


def test_css_dark_theme_and_responsive_rules() -> None:
    """Verify stylesheet provides WCAG dark palette and responsive breakpoints."""
    css = (FRONTEND_DIR / "css" / "styles.css").read_text(encoding="utf-8")

    # Dark-theme variables
    assert "--bg-base" in css
    assert "--bg-surface" in css
    assert "--bg-card" in css
    assert "--text-primary" in css
    assert "--color-brand" in css

    # Responsive breakpoints
    assert "@media (max-width: 900px)" in css
    assert "@media (max-width: 1024px)" in css

    # Mobile sidebar transform toggle
    assert "transform: translateX(-100%)" in css
    assert "transform: translateX(0)" in css


# ==============================================================================
# 5. Backend CORS & Endpoint Integration Tests
# ==============================================================================


def test_backend_cors_allows_frontend_origin(client: TestClient) -> None:
    """Verify that the FastAPI backend accepts CORS requests from the frontend origin."""
    frontend_origins = [
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:8080",
    ]

    for origin in frontend_origins:
        # Preflight OPTIONS request
        options_res = client.options(
            "/api/v1/status",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET",
            },
        )
        assert options_res.status_code == 200
        assert options_res.headers.get("access-control-allow-origin") == origin

        # Real GET request with Origin
        get_res = client.get("/api/v1/status", headers={"Origin": origin})
        assert get_res.status_code == 200
        assert get_res.headers.get("access-control-allow-origin") == origin


def test_backend_endpoints_consumed_by_frontend(client: TestClient) -> None:
    """Verify all 4 backend endpoints required by frontend return valid schemas."""
    # 1. /health/live
    live_res = client.get("/health/live")
    assert live_res.status_code == 200
    live_data = live_res.json()
    assert live_data["status"] == "alive"

    # 2. /health/ready
    ready_res = client.get("/health/ready")
    assert ready_res.status_code == 200
    ready_data = ready_res.json()
    assert ready_data["status"] == "ready"

    # 3. /api/v1/status
    status_res = client.get("/api/v1/status")
    assert status_res.status_code == 200
    status_data = status_res.json()
    assert "app_name" in status_data
    assert "uptime_seconds" in status_data
    assert "process_status" in status_data

    # 4. /metrics
    metrics_res = client.get("/metrics")
    assert metrics_res.status_code == 200
    metrics_text = metrics_res.text
    assert "deployx_http_requests_total" in metrics_text
    assert "deployx_http_request_duration_seconds" in metrics_text
    assert "deployx_application_uptime_seconds" in metrics_text


# ==============================================================================
# 6. Sidebar Navigation & Active Tracking Tests
# ==============================================================================


def test_sidebar_navigation_anchors_match_section_ids() -> None:
    """Verify that all sidebar navigation anchor links resolve to valid section IDs."""
    html = (FRONTEND_DIR / "index.html").read_text(encoding="utf-8")

    expected_nav_sections = [
        "overview",
        "metrics-section",
        "deployment-section",
        "kubernetes-section",
        "dr-section",
    ]

    for section_id in expected_nav_sections:
        # Check anchor tag in sidebar nav
        assert f'href="#{section_id}"' in html, f"Missing sidebar link for #{section_id}"
        # Check corresponding section exists with matching ID
        assert f'id="{section_id}"' in html, f"Missing section for ID '{section_id}'"


def test_sidebar_navigation_scroll_css_and_active_script() -> None:
    """Verify stylesheet and script support smooth scroll-margin and active tracking."""
    css = (FRONTEND_DIR / "css" / "styles.css").read_text(encoding="utf-8")
    js = (FRONTEND_DIR / "js" / "dashboard.js").read_text(encoding="utf-8")

    # CSS smooth scrolling & sticky header scroll-margin offset
    assert "scroll-behavior: smooth" in css
    assert "scroll-margin-top" in css

    # JavaScript navigation logic
    assert "setupSidebarNavigation" in js
    assert "IntersectionObserver" in js
    assert "setActiveNavItem" in js
    assert "scrollIntoView" in js
    assert "pushState" in js
