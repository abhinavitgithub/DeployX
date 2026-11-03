"""DeployX Pytest Test Configuration and Fixtures.

Provides configured FastAPI TestClient and isolated state for testing.
"""

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from backend.app.main import app
from backend.app.services.state import app_state


@pytest.fixture(autouse=True)
def reset_application_state() -> Generator[None]:
    """Ensure clean application readiness before each test."""
    app_state.set_ready(True)
    yield
    app_state.set_ready(True)


@pytest.fixture
def client() -> Generator[TestClient]:
    """Provide a synchronous test client instance with base URL."""
    with TestClient(app=app, base_url="http://testserver") as test_client:
        yield test_client
