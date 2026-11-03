"""Automated Tests for DeployX Docker Containerization Configuration.

Validates:
1. Presence of all Phase 3 containerization assets and ignore rules.
2. Production hardening in backend/Dockerfile (slim base, non-root user, healthcheck).
3. Production hardening in frontend/Dockerfile (alpine base, static copies, healthcheck).
4. Reverse-proxy routing integrity and cache headers in frontend/nginx.conf.
5. Compose service topology, networking, dependencies, and healthchecks in compose.yaml.
"""

from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
BACKEND_DIR = ROOT_DIR / "backend"
FRONTEND_DIR = ROOT_DIR / "frontend"
INFRA_DOCKER_DIR = ROOT_DIR / "infrastructure" / "docker"


def test_docker_files_exist() -> None:
    """Verify all containerization manifests and documentation exist."""
    required_files = [
        ROOT_DIR / "compose.yaml",
        ROOT_DIR / ".dockerignore",
        BACKEND_DIR / "Dockerfile",
        BACKEND_DIR / ".dockerignore",
        FRONTEND_DIR / "Dockerfile",
        FRONTEND_DIR / "nginx.conf",
        FRONTEND_DIR / ".dockerignore",
        INFRA_DOCKER_DIR / "README.md",
    ]
    for file_path in required_files:
        assert file_path.is_file(), f"Missing required Docker file: {file_path}"


def test_backend_dockerfile_hardening() -> None:
    """Verify backend Dockerfile complies with security and reliability standards."""
    content = (BACKEND_DIR / "Dockerfile").read_text(encoding="utf-8")

    # Base image must be slim Python 3.14
    assert "FROM python:3.14-slim" in content

    # Non-root security
    assert "groupadd -g 10001 deployx" in content
    assert "useradd -u 10001 -g deployx" in content
    assert "USER deployx" in content

    # Network exposure & port
    assert "EXPOSE 8000" in content

    # Health check probe
    assert "HEALTHCHECK" in content
    assert "http://127.0.0.1:8000/health/live" in content

    # Unbuffered logging
    assert "PYTHONUNBUFFERED=1" in content

    # Clean package list
    assert "rm -rf /var/lib/apt/lists/*" in content


def test_frontend_dockerfile_hardening() -> None:
    """Verify frontend Dockerfile uses minimal Alpine image and health checks."""
    content = (FRONTEND_DIR / "Dockerfile").read_text(encoding="utf-8")

    # Base image must be nginx:alpine
    assert "FROM nginx:alpine" in content

    # Configuration and assets copying
    assert "COPY nginx.conf /etc/nginx/conf.d/default.conf" in content
    assert "COPY index.html /usr/share/nginx/html/" in content
    assert "COPY css/ /usr/share/nginx/html/css/" in content
    assert "COPY js/ /usr/share/nginx/html/js/" in content

    # Port exposure
    assert "EXPOSE 80" in content

    # Alpine native wget health check
    assert "HEALTHCHECK" in content
    assert "wget -q --spider http://127.0.0.1:80/" in content


def test_nginx_reverse_proxy_configuration() -> None:
    """Verify Nginx proxies all required backend routes with anti-caching headers."""
    content = (FRONTEND_DIR / "nginx.conf").read_text(encoding="utf-8")

    # Required reverse-proxy routes
    required_routes = [
        "location /health/",
        "location /api/",
        "location /metrics",
        "location /docs",
        "location /openapi.json",
    ]
    for route in required_routes:
        assert route in content, f"Missing route in nginx.conf: {route}"

    # Target proxy pass
    assert "proxy_pass http://backend:8000;" in content

    # Cache prevention on dynamic routes
    assert 'add_header Cache-Control "no-store, no-cache, must-revalidate' in content

    # Compression
    assert "gzip on;" in content


def test_compose_yaml_topology_and_contracts() -> None:
    """Verify compose.yaml specifies services, networks, dependencies, and healthchecks."""
    content = (ROOT_DIR / "compose.yaml").read_text(encoding="utf-8")

    # Services
    assert "backend:" in content
    assert "frontend:" in content

    # Port mappings
    assert '"8000:8000"' in content
    assert '"3000:80"' in content

    # Dependency contract: frontend waits for backend to be healthy
    assert "depends_on:" in content
    assert "condition: service_healthy" in content

    # Dedicated bridge network
    assert "networks:" in content
    assert "deployx-network:" in content
    assert "driver: bridge" in content

    # Restart policies
    assert "restart: unless-stopped" in content
