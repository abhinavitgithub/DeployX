# DeployX Backend - Production Container Image
# Multi-stage/Slim production container adhering to least-privilege security principles

FROM python:3.14-slim

# Prevent generation of .pyc files and enable unbuffered stdout/stderr logging
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

# Install runtime security packages (curl for container health checks)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Create a dedicated, non-privileged system user and group (UID/GID 10001)
RUN groupadd -g 10001 deployx && \
    useradd -u 10001 -g deployx -s /bin/sh -d /app deployx

# Copy and install pinned Python dependencies first for optimal Docker layer caching
COPY requirements.txt /app/backend/requirements.txt
RUN pip install --no-cache-dir -r /app/backend/requirements.txt

# Copy application source tree
COPY . /app/backend/

# Ensure directory ownership belongs to the unprivileged service user
RUN chown -R deployx:deployx /app

# Switch to non-root execution context
USER deployx

# Expose backend service port
EXPOSE 8000

# Container liveness health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://127.0.0.1:8000/health/live || exit 1

# Start production ASGI server with non-root privileges
CMD ["python", "-m", "uvicorn", "backend.app.main:app", "--host", "0.0.0.0", "--port", "8000"]
