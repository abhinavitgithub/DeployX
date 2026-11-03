"""DeployX System Status API Endpoint.

Provides application metadata, runtime environment, and operational telemetry.
Does not expose secrets, credentials, or internal configuration values.
"""

from datetime import UTC, datetime

from fastapi import APIRouter, status
from pydantic import BaseModel

from backend.app.config import settings
from backend.app.services.state import app_state

router = APIRouter(prefix="/api/v1", tags=["System Status"])


class StatusResponse(BaseModel):
    """System status response schema."""

    app_name: str
    version: str
    environment: str
    uptime_seconds: float
    process_status: str
    readiness_status: str
    timestamp: str


@router.get(
    "/status",
    response_model=StatusResponse,
    status_code=status.HTTP_200_OK,
    summary="Application Status",
    description="Returns sanitized runtime status, versioning, environment, and uptime.",
)
async def get_system_status() -> StatusResponse:
    """Return non-sensitive application runtime health and status."""
    return StatusResponse(
        app_name=settings.APP_NAME,
        version=settings.APP_VERSION,
        environment=settings.APP_ENV,
        uptime_seconds=app_state.get_uptime_seconds(),
        process_status="running",
        readiness_status="ready" if app_state.is_ready() else "degraded",
        timestamp=datetime.now(UTC).isoformat(),
    )
