"""DeployX API Routes Package."""

from backend.app.api.routes.health import router as health_router
from backend.app.api.routes.metrics import router as metrics_router
from backend.app.api.routes.status import router as status_router

__all__ = ["health_router", "metrics_router", "status_router"]
