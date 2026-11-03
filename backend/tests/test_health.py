"""Tests for DeployX Root, Liveness, and Readiness Probe Endpoints."""

from datetime import datetime

from fastapi.testclient import TestClient

from backend.app.config import settings
from backend.app.services.state import app_state


def test_root_endpoint_returns_metadata(client: TestClient) -> None:
    """Validate that GET / returns accurate application metadata and docs link."""
    response = client.get("/")
    assert response.status_code == 200

    data = response.json()
    assert data["app_name"] == settings.APP_NAME
    assert data["version"] == settings.APP_VERSION
    assert "description" in data
    assert data["docs_url"] == settings.DOCS_URL
    assert "X-Request-ID" in response.headers


def test_liveness_probe_returns_200_and_alive(client: TestClient) -> None:
    """Validate that GET /health/live returns HTTP 200 and alive status."""
    response = client.get("/health/live")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "alive"
    assert "timestamp" in data

    # Verify timestamp format is valid ISO 8601
    parsed_time = datetime.fromisoformat(data["timestamp"])
    assert parsed_time is not None


def test_readiness_probe_returns_200_when_ready(client: TestClient) -> None:
    """Validate that GET /health/ready returns HTTP 200 and ready state."""
    app_state.set_ready(True)
    response = client.get("/health/ready")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "ready"
    assert data["checks"]["system"] == "ok"
    assert "timestamp" in data


def test_readiness_probe_returns_503_when_not_ready(client: TestClient) -> None:
    """Validate that GET /health/ready returns HTTP 503 when readiness is degraded."""
    app_state.set_ready(False)
    response = client.get("/health/ready")
    assert response.status_code == 503

    data = response.json()
    assert data["status"] == "not_ready"
    assert "system" in data["checks"]
