"""DeployX Prometheus Telemetry & Metrics Service.

Defines standardized, bounded Prometheus metrics for HTTP traffic and uptime.
Ensures zero high-cardinality label explosion.
"""

from prometheus_client import Counter, Gauge, Histogram

from backend.app.services.state import app_state

# Request count counter (bounded labels: method, handler, status)
HTTP_REQUESTS_TOTAL = Counter(
    "deployx_http_requests_total",
    "Total number of HTTP requests handled by the DeployX backend",
    ["method", "handler", "status"],
)

# Latency histogram with standard service-level objective buckets
HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "deployx_http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "handler", "status"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

# Application uptime gauge
APPLICATION_UPTIME_SECONDS = Gauge(
    "deployx_application_uptime_seconds",
    "Application uptime in seconds since process initialization",
)

# Release metadata gauge (always set to 1.0 with fixed categorical labels)
APPLICATION_INFO = Gauge(
    "deployx_application_info",
    "DeployX application version and metadata",
    ["app_name", "version", "environment"],
)


def init_app_info(app_name: str, version: str, environment: str) -> None:
    """Set the application release info metric."""
    APPLICATION_INFO.labels(
        app_name=app_name,
        version=version,
        environment=environment,
    ).set(1.0)


def update_uptime_metric() -> None:
    """Synchronize the uptime gauge with the current process uptime."""
    APPLICATION_UPTIME_SECONDS.set(app_state.get_uptime_seconds())


def record_http_metrics(
    method: str, handler: str, status_code: int, duration_seconds: float
) -> None:
    """Record request count and latency metrics with normalized bounded labels."""
    # Exclude /metrics from tracking to avoid self-monitoring amplification
    if handler == "/metrics":
        return

    status_str = str(status_code)
    HTTP_REQUESTS_TOTAL.labels(
        method=method,
        handler=handler,
        status=status_str,
    ).inc()

    HTTP_REQUEST_DURATION_SECONDS.labels(
        method=method,
        handler=handler,
        status=status_str,
    ).observe(duration_seconds)
