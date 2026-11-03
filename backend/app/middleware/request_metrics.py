"""DeployX Request Correlation ID, Structured Logging & Metrics Middleware.

Intercepts all HTTP traffic to:
1. Validate or generate request correlation IDs (X-Request-ID).
2. Measure request latency with high-resolution timers.
3. Exclude /metrics from self-amplifying metrics.
4. Normalize route templates to prevent label cardinality explosion.
5. Emit structured JSON completion logs.
"""

import logging
import re
import time
import uuid
from collections.abc import Callable

from fastapi import Request, Response
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp

from backend.app.logging_config import request_id_ctx
from backend.app.services.metrics import record_http_metrics

logger = logging.getLogger("deployx.middleware")

# Strict regex for incoming X-Request-ID validation (alphanumeric, hyphen, underscore, 1-128 chars)
VALID_REQUEST_ID_REGEX = re.compile(r"^[a-zA-Z0-9_\-]{1,128}$")


def sanitize_or_generate_request_id(incoming_id: str | None) -> str:
    """Validate incoming request ID or generate a standard UUID4 string."""
    if incoming_id and VALID_REQUEST_ID_REGEX.match(incoming_id):
        return incoming_id
    return str(uuid.uuid4())


def get_normalized_handler(request: Request) -> str:
    """Extract route template path to avoid high-cardinality metric labels.

    Falls back to 'unmatched' if the path does not map to a registered FastAPI route.
    """
    route = request.scope.get("route")
    if route and hasattr(route, "path"):
        return route.path

    # Check common known unrouted endpoints or mark as unmatched
    raw_path = request.url.path
    if raw_path in {"/", "/health/live", "/health/ready", "/metrics", "/docs", "/openapi.json"}:
        return raw_path

    return "unmatched"


class RequestMetricsMiddleware(BaseHTTPMiddleware):
    """ASGI Middleware managing request correlation IDs, metrics collection, and logging."""

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """Process incoming request, measure latency, track telemetry, and log result."""
        # 1. Resolve and validate correlation ID
        incoming_header = request.headers.get("X-Request-ID")
        req_id = sanitize_or_generate_request_id(incoming_header)

        # Set context variables and request state
        token = request_id_ctx.set(req_id)
        request.state.request_id = req_id

        start_time = time.perf_counter()
        status_code = 500
        recorded_metrics = False

        try:
            response: Response = await call_next(request)
            status_code = response.status_code
        except Exception as exc:
            duration = time.perf_counter() - start_time
            duration_ms = round(duration * 1000, 2)
            handler = get_normalized_handler(request)

            record_http_metrics(
                method=request.method,
                handler=handler,
                status_code=500,
                duration_seconds=duration,
            )
            recorded_metrics = True

            logger.error(
                f"Unhandled exception during {request.method} {request.url.path}: {exc}",
                exc_info=True,
                extra={
                    "http_method": request.method,
                    "route": handler,
                    "status_code": 500,
                    "duration_ms": duration_ms,
                },
            )

            response = JSONResponse(
                status_code=500,
                content={
                    "error": "Internal Server Error",
                    "message": "An unexpected error occurred while processing the request.",
                    "request_id": req_id,
                },
            )
        finally:
            duration = time.perf_counter() - start_time
            duration_ms = round(duration * 1000, 2)
            handler = get_normalized_handler(request)

            if not recorded_metrics:
                record_http_metrics(
                    method=request.method,
                    handler=handler,
                    status_code=status_code,
                    duration_seconds=duration,
                )

            # Attach correlation ID to outgoing response headers
            response.headers["X-Request-ID"] = req_id

            # Emit structured access log
            log_level = logging.INFO
            if status_code >= 500:
                log_level = logging.ERROR
            elif status_code >= 400:
                log_level = logging.WARNING

            logger.log(
                log_level,
                f"{request.method} {request.url.path} responded {status_code} in {duration_ms}ms",
                extra={
                    "http_method": request.method,
                    "route": handler,
                    "status_code": status_code,
                    "duration_ms": duration_ms,
                },
            )

            request_id_ctx.reset(token)

        return response
