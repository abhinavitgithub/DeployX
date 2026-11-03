"""DeployX Application Runtime State Manager.

Tracks process startup timestamp, uptime, and system readiness.
"""

import time
from datetime import UTC, datetime


class ApplicationState:
    """Manages in-memory application lifecycle state and readiness."""

    def __init__(self) -> None:
        self._start_time: float = time.time()
        self._ready: bool = True
        self._startup_timestamp: str = datetime.now(UTC).isoformat()

    def get_start_time(self) -> float:
        """Return the epoch timestamp when the application started."""
        return self._start_time

    def get_uptime_seconds(self) -> float:
        """Calculate total elapsed running time in seconds."""
        return round(time.time() - self._start_time, 2)

    def is_ready(self) -> bool:
        """Return whether the application is ready to accept incoming traffic."""
        return self._ready

    def set_ready(self, ready: bool) -> None:
        """Update application readiness status."""
        self._ready = ready

    def reset_timer(self) -> None:
        """Reset start time (useful in test harnesses)."""
        self._start_time = time.time()


app_state = ApplicationState()
