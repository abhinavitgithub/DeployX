"""Tests for DeployX Application Status API (/api/v1/status)."""

import time
from datetime import datetime

from fastapi.testclient import TestClient

from backend.app.config import settings
from backend.app.services.state import app_state


def test_status_endpoint_returns_expected_fields(client: TestClient) -> None:
    """Validate that GET /api/v1/status returns all required operational metadata."""
    response = client.get("/api/v1/status")
    assert response.status_code == 200

    data = response.json()
    assert data["app_name"] == settings.APP_NAME
    assert data["version"] == settings.APP_VERSION
    assert data["environment"] == settings.APP_ENV
    assert isinstance(data["uptime_seconds"], int | float)
    assert data["uptime_seconds"] >= 0.0
    assert data["process_status"] == "running"
    assert data["readiness_status"] == "ready"
    assert "timestamp" in data

    # Verify timestamp format is valid ISO 8601
    parsed_time = datetime.fromisoformat(data["timestamp"])
    assert parsed_time is not None


def test_status_uptime_increases(client: TestClient) -> None:
    """Validate that reported uptime increases monotonically over time."""
    response1 = client.get("/api/v1/status")
    uptime1 = response1.json()["uptime_seconds"]

    time.sleep(0.05)

    response2 = client.get("/api/v1/status")
    uptime2 = response2.json()["uptime_seconds"]

    assert uptime2 >= uptime1


def test_status_endpoint_never_exposes_secrets(client: TestClient) -> None:
    """Verify that no sensitive environment variables or secrets leak in status output."""
    response = client.get("/api/v1/status")
    data = response.json()

    forbidden_keywords = [
        "secret",
        "key",
        "password",
        "token",
        "credential",
        "aws_access",
        "private",
    ]

    for key, value in data.items():
        for keyword in forbidden_keywords:
            assert keyword not in key.lower()
            if isinstance(value, str):
                assert keyword not in value.lower()


def test_status_reflects_readiness_state_change(client: TestClient) -> None:
    """Verify that the status endpoint reflects degraded readiness accurately."""
    app_state.set_ready(False)
    response = client.get("/api/v1/status")
    assert response.status_code == 200
    assert response.json()["readiness_status"] == "degraded"
