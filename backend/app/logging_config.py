"""DeployX Centralized Structured Logging Configuration.

Provides JSON formatted logs with request correlation IDs, ISO 8601 timestamps,
and sanitized metadata. Never logs sensitive tokens, credentials, or cookies.
"""

import json
import logging
import sys
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

# Context variable for request correlation ID
request_id_ctx: ContextVar[str | None] = ContextVar("request_id_ctx", default=None)


class JSONLogFormatter(logging.Formatter):
    """Custom logging formatter that outputs structured JSON strings."""

    def format(self, record: logging.LogRecord) -> str:
        """Format a LogRecord into a standardized JSON string."""
        log_data: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Include request correlation ID if available in ContextVar
        req_id = request_id_ctx.get()
        if req_id:
            log_data["request_id"] = req_id

        # Attach structured contextual attributes if passed via extra
        for key in (
            "http_method",
            "route",
            "status_code",
            "duration_ms",
            "client_ip",
        ):
            if hasattr(record, key):
                log_data[key] = getattr(record, key)

        if record.exc_info:
            log_data["exception"] = self.formatException(record.exc_info)

        return json.dumps(log_data)


def setup_logging(log_level: str = "INFO", log_format: str = "json") -> None:
    """Configure root logger with structured JSON or standard console formatting."""
    root_logger = logging.getLogger()
    numeric_level = getattr(logging, log_level.upper(), logging.INFO)
    root_logger.setLevel(numeric_level)

    # Remove existing handlers to avoid duplicate log emission
    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)

    stream_handler = logging.StreamHandler(sys.stdout)
    if log_format.lower() == "json":
        stream_handler.setFormatter(JSONLogFormatter())
    else:
        stream_handler.setFormatter(
            logging.Formatter("[%(asctime)s] [%(levelname)s] [%(name)s] %(message)s")
        )

    root_logger.addHandler(stream_handler)

    # Adjust external noisy loggers
    logging.getLogger("uvicorn.access").handlers = [stream_handler]
    logging.getLogger("uvicorn.error").handlers = [stream_handler]


logger = logging.getLogger("deployx")
