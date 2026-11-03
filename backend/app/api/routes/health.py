"""DeployX Health & Readiness Probes.

Provides liveness and readiness probes for orchestrators (Kubernetes / Docker Compose)
and load balancers.
"""

from datetime import UTC, datetime

from fastapi import APIRouter, Response, status
from pydantic import BaseModel

from backend.app.services.state import app_state

router = APIRouter(prefix="/health", tags=["Health Probes"])


class LivenessResponse(BaseModel):
    """Liveness probe response payload."""

    status: str
    timestamp: str


class ReadinessResponse(BaseModel):
    """Readiness probe response payload."""

    status: str
    timestamp: str
    checks: dict[str, str]


@router.get(
    "/live",
    response_model=LivenessResponse,
    status_code=status.HTTP_200_OK,
    summary="Liveness Probe",
    description="Indicates whether the process is alive. Does not depend on external dependencies.",
)
async def liveness_probe() -> LivenessResponse:
    """Return process alive status."""
    return LivenessResponse(
        status="alive",
        timestamp=datetime.now(UTC).isoformat(),
    )


@router.get(
    "/ready",
    response_model=ReadinessResponse,
    status_code=status.HTTP_200_OK,
    responses={
        503: {
            "description": "Application is not ready to receive traffic",
            "model": ReadinessResponse,
        }
    },
    summary="Readiness Probe",
    description="Indicates whether the application is fully initialized and ready to accept traffic.",
)
async def readiness_probe(response: Response) -> ReadinessResponse:
    """Return application readiness status and internal health checks."""
    is_ready = app_state.is_ready()
    current_time = datetime.now(UTC).isoformat()

    if not is_ready:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return ReadinessResponse(
            status="not_ready",
            timestamp=current_time,
            checks={"system": "initializing_or_degraded"},
        )

    return ReadinessResponse(
        status="ready",
        timestamp=current_time,
        checks={"system": "ok"},
    )
