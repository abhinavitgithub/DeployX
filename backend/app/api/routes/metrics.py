"""DeployX Prometheus Metrics Endpoint.

Exposes application telemetry and RED metrics in standard Prometheus exposition format.
"""

from fastapi import APIRouter, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from backend.app.services.metrics import update_uptime_metric

router = APIRouter(tags=["Telemetry & Metrics"])


@router.get(
    "/metrics",
    summary="Prometheus Metrics",
    description="Returns application performance, request rates, latency, and uptime in Prometheus format.",
    response_class=Response,
)
async def get_metrics() -> Response:
    """Expose Prometheus formatted metrics."""
    # Synchronize uptime gauge before exporting
    update_uptime_metric()

    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )
