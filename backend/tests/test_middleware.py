"""Tests for DeployX Correlation ID, Request Tracking, and Error Handling Middleware."""

import re

from fastapi import APIRouter
from fastapi.testclient import TestClient

from backend.app.main import app

mock_router = APIRouter()


@mock_router.get("/test/simulate-crash")
async def simulate_crash() -> None:
    """Endpoint to trigger an unhandled exception for middleware test."""
    raise RuntimeError("Simulated crash for middleware error testing")


# Register crash endpoint for testing
app.include_router(mock_router)


def test_request_id_generated_when_omitted(client: TestClient) -> None:
    """Verify that an omitted X-Request-ID header results in a generated UUID."""
    response = client.get("/")
    assert response.status_code == 200
    assert "X-Request-ID" in response.headers

    req_id = response.headers["X-Request-ID"]
    # Check UUID format (hex with hyphens)
    assert len(req_id) >= 32
    assert re.match(r"^[0-9a-fA-F\-]{32,36}$", req_id) is not None


def test_request_id_preserved_when_valid(client: TestClient) -> None:
    """Verify that a valid incoming X-Request-ID is trusted and returned."""
    custom_id = "deployx-corr-id-9988-abc"
    response = client.get("/", headers={"X-Request-ID": custom_id})
    assert response.status_code == 200
    assert response.headers.get("X-Request-ID") == custom_id


def test_request_id_replaced_when_malformed(client: TestClient) -> None:
    """Verify that malformed or dangerous characters in X-Request-ID are rejected."""
    malformed_id = "injected<script>alert(1)</script>"
    response = client.get("/", headers={"X-Request-ID": malformed_id})
    assert response.status_code == 200
    returned_id = response.headers.get("X-Request-ID")
    assert returned_id != malformed_id
    assert "<script>" not in returned_id


def test_request_id_replaced_when_excessively_long(client: TestClient) -> None:
    """Verify that request IDs exceeding 128 characters are rejected and replaced."""
    oversized_id = "a" * 200
    response = client.get("/", headers={"X-Request-ID": oversized_id})
    assert response.status_code == 200
    returned_id = response.headers.get("X-Request-ID")
    assert returned_id != oversized_id
    assert len(returned_id) <= 36


def test_invalid_routes_return_404_with_request_id(client: TestClient) -> None:
    """Verify that 404 responses include an X-Request-ID header."""
    response = client.get("/api/v1/invalid-route-does-not-exist")
    assert response.status_code == 404
    assert "X-Request-ID" in response.headers


def test_unmatched_route_metrics_uses_bounded_label(client: TestClient) -> None:
    """Verify that arbitrary 404 paths are normalized to 'unmatched' in metrics."""
    client.get("/arbitrary-unmatched-path-12345")
    metrics_res = client.get("/metrics")
    content = metrics_res.text

    assert 'handler="unmatched"' in content
    assert "arbitrary-unmatched-path-12345" not in content


def test_unhandled_exception_returns_500_with_correlation_id(client: TestClient) -> None:
    """Verify that an unhandled crash returns a structured 500 response with request_id."""
    custom_id = "crash-test-id-123"
    response = client.get("/test/simulate-crash", headers={"X-Request-ID": custom_id})
    assert response.status_code == 500
    assert response.headers.get("X-Request-ID") == custom_id

    data = response.json()
    assert data["error"] == "Internal Server Error"
    assert data["request_id"] == custom_id
