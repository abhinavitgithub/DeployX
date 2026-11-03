"""DeployX Core FastAPI Application Entrypoint.

Central health, telemetry, and deployment status service for the DeployX platform.
"""

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from backend.app.api.routes.health import router as health_router
from backend.app.api.routes.metrics import router as metrics_router
from backend.app.api.routes.status import router as status_router
from backend.app.config import settings
from backend.app.logging_config import logger, setup_logging
from backend.app.middleware.request_metrics import RequestMetricsMiddleware
from backend.app.services.metrics import init_app_info
from backend.app.services.state import app_state


class RootResponse(BaseModel):
    """Root endpoint response schema."""

    app_name: str
    version: str
    description: str
    docs_url: str


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
    """Application lifespan manager for initialization and graceful teardown."""
    # Initialize centralized structured logging
    setup_logging(log_level=settings.LOG_LEVEL, log_format=settings.LOG_FORMAT)

    # Initialize Prometheus metadata gauge
    init_app_info(
        app_name=settings.APP_NAME,
        version=settings.APP_VERSION,
        environment=settings.APP_ENV,
    )

    # Mark app state initialized
    app_state.set_ready(True)

    logger.info(
        f"Starting {settings.APP_NAME} v{settings.APP_VERSION} in {settings.APP_ENV} mode",
        extra={"route": "/", "status_code": 200},
    )

    yield

    logger.info(f"Shutting down {settings.APP_NAME}")


def create_application() -> FastAPI:
    """Build and configure the FastAPI application instance."""
    application = FastAPI(
        title=settings.APP_NAME,
        version=settings.APP_VERSION,
        description=settings.APP_DESCRIPTION,
        docs_url=settings.DOCS_URL,
        openapi_url="/openapi.json",
        lifespan=lifespan,
    )

    # 1. Register Request Correlation & Telemetry Middleware (outer layer)
    application.add_middleware(RequestMetricsMiddleware)

    # 2. Register Secure CORS Middleware
    application.add_middleware(
        CORSMiddleware,
        allow_origins=settings.ALLOWED_ORIGINS,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allow_headers=["*"],
    )

    # 3. Include API Routers
    application.include_router(health_router)
    application.include_router(status_router)
    application.include_router(metrics_router)

    # 4. Root Endpoint
    @application.get(
        "/",
        response_model=RootResponse,
        status_code=status.HTTP_200_OK,
        tags=["General"],
        summary="Service Root Information",
        description="Returns basic application metadata and documentation URL.",
    )
    async def root() -> RootResponse:
        """Return application metadata and docs link."""
        return RootResponse(
            app_name=settings.APP_NAME,
            version=settings.APP_VERSION,
            description=settings.APP_DESCRIPTION,
            docs_url=settings.DOCS_URL,
        )

    return application


app = create_application()
