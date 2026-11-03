"""Tests for DeployX Prometheus Telemetry and Metrics (/metrics)."""

from fastapi.testclient import TestClient

from backend.app.config import settings


def test_metrics_endpoint_returns_prometheus_format(client: TestClient) -> None:
    """Validate that GET /metrics returns standard Prometheus text format."""
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "text/plain" in response.headers["content-type"]


def test_metrics_contains_all_required_metrics(client: TestClient) -> None:
    """Ensure all required DeployX metrics are registered and exported."""
    # Send at least one non-metrics request so request metrics are materialized
    client.get("/")

    response = client.get("/metrics")
    content = response.text

    assert "deployx_http_requests_total" in content
    assert "deployx_http_request_duration_seconds" in content
    assert "deployx_application_uptime_seconds" in content
    assert "deployx_application_info" in content


def test_metrics_endpoint_excludes_self_from_request_metrics(client: TestClient) -> None:
    """Verify that requests to /metrics do not generate request count metrics for itself."""
    # Scrape metrics multiple times
    client.get("/metrics")
    client.get("/metrics")
    response = client.get("/metrics")

    content = response.text
    # Handler label should not equal "/metrics" in deployx_http_requests_total
    assert 'handler="/metrics"' not in content


def test_request_count_metrics_increment_on_traffic(client: TestClient) -> None:
    """Verify that traffic to endpoints records method, handler, and status."""
    client.get("/health/live")

    response = client.get("/metrics")
    content = response.text

    assert 'method="GET"' in content
    assert 'handler="/health/live"' in content
    assert 'status="200"' in content


def test_application_info_contains_configured_metadata(client: TestClient) -> None:
    """Verify that deployx_application_info includes app_name, version, and environment."""
    response = client.get("/metrics")
    content = response.text

    assert f'app_name="{settings.APP_NAME}"' in content
    assert f'version="{settings.APP_VERSION}"' in content
    assert f'environment="{settings.APP_ENV}"' in content
