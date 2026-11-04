"""Automated Tests for DeployX Kubernetes Manifests & Deployment Configuration.

Validates:
1. Presence of all Phase 4 & Phase 5 Kubernetes manifests and documentation.
2. Valid YAML parsing across all manifest specifications.
3. Namespace definition integrity (deployx).
4. Backend Blue Deployment & Service contracts (health probes, resource limits, port 8000).
5. Backend Green Deployment contracts (health probes, resource limits, port 8000).
6. Frontend Deployment & NodePort Service contracts (health probes, resource limits, port 80, NodePort 30080).
7. Backend DNS alias Service contract (Blue-Green traffic switching selector).
"""

from pathlib import Path

import yaml

ROOT_DIR = Path(__file__).resolve().parent.parent
K8S_DIR = ROOT_DIR / "infrastructure" / "kubernetes"


def test_kubernetes_manifest_files_exist() -> None:
    """Verify all required Kubernetes manifests and runbook documentation exist."""
    required_files = [
        K8S_DIR / "namespace.yaml",
        K8S_DIR / "backend.yaml",
        K8S_DIR / "backend-green.yaml",
        K8S_DIR / "backend-alias.yaml",
        K8S_DIR / "frontend.yaml",
        K8S_DIR / "README.md",
    ]
    for file_path in required_files:
        assert file_path.is_file(), f"Missing required Kubernetes file: {file_path}"


def test_namespace_manifest() -> None:
    """Verify namespace manifest declares deployx namespace."""
    content = (K8S_DIR / "namespace.yaml").read_text(encoding="utf-8")
    data = yaml.safe_load(content)

    assert data["apiVersion"] == "v1"
    assert data["kind"] == "Namespace"
    assert data["metadata"]["name"] == "deployx"
    assert data["metadata"]["labels"]["app.kubernetes.io/part-of"] == "deployx"


def test_backend_deployment_and_service() -> None:
    """Verify backend Blue Deployment and ClusterIP Service configurations."""
    content = (K8S_DIR / "backend.yaml").read_text(encoding="utf-8")
    docs = list(yaml.safe_load_all(content))

    assert len(docs) == 2, "backend.yaml must define Deployment and Service"
    deployment = docs[0]
    service = docs[1]

    # Deployment assertions (Blue environment)
    assert deployment["kind"] == "Deployment"
    assert deployment["metadata"]["name"] == "deployx-backend"
    assert deployment["metadata"]["namespace"] == "deployx"
    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["selector"]["matchLabels"] == {
        "app": "deployx-backend",
        "deployment-color": "blue",
    }
    assert deployment["spec"]["template"]["metadata"]["labels"] == {
        "app": "deployx-backend",
        "deployment-color": "blue",
    }

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert container["name"] == "backend"
    assert container["image"] == "deployx-backend:latest"
    assert container["imagePullPolicy"] == "IfNotPresent"
    assert container["ports"][0]["containerPort"] == 8000

    # Probes
    assert container["readinessProbe"]["httpGet"]["path"] == "/health/ready"
    assert container["livenessProbe"]["httpGet"]["path"] == "/health/live"

    # Resource requests & limits
    assert container["resources"]["requests"]["cpu"] == "100m"
    assert container["resources"]["requests"]["memory"] == "128Mi"
    assert container["resources"]["limits"]["cpu"] == "500m"
    assert container["resources"]["limits"]["memory"] == "384Mi"

    # Service assertions
    assert service["kind"] == "Service"
    assert service["metadata"]["name"] == "deployx-backend"
    assert service["metadata"]["namespace"] == "deployx"
    assert service["spec"]["type"] == "ClusterIP"
    assert service["spec"]["selector"] == {"app": "deployx-backend"}
    assert service["spec"]["ports"][0]["port"] == 8000
    assert service["spec"]["ports"][0]["targetPort"] == "http"


def test_backend_green_deployment() -> None:
    """Verify backend Green Deployment configuration."""
    content = (K8S_DIR / "backend-green.yaml").read_text(encoding="utf-8")
    deployment = yaml.safe_load(content)

    assert deployment["kind"] == "Deployment"
    assert deployment["metadata"]["name"] == "deployx-backend-green"
    assert deployment["metadata"]["namespace"] == "deployx"
    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["selector"]["matchLabels"] == {
        "app": "deployx-backend",
        "deployment-color": "green",
    }
    assert deployment["spec"]["template"]["metadata"]["labels"] == {
        "app": "deployx-backend",
        "deployment-color": "green",
    }

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert container["name"] == "backend"
    assert container["image"] == "deployx-backend:latest"
    assert container["imagePullPolicy"] == "IfNotPresent"
    assert container["ports"][0]["containerPort"] == 8000

    # Probes
    assert container["readinessProbe"]["httpGet"]["path"] == "/health/ready"
    assert container["livenessProbe"]["httpGet"]["path"] == "/health/live"

    # Resource requests & limits
    assert container["resources"]["requests"]["cpu"] == "100m"
    assert container["resources"]["requests"]["memory"] == "128Mi"
    assert container["resources"]["limits"]["cpu"] == "500m"
    assert container["resources"]["limits"]["memory"] == "384Mi"


def test_backend_alias_service() -> None:
    """Verify backend DNS alias Service routes initially to Blue deployment."""
    content = (K8S_DIR / "backend-alias.yaml").read_text(encoding="utf-8")
    data = yaml.safe_load(content)

    assert data["kind"] == "Service"
    assert data["metadata"]["name"] == "backend"
    assert data["metadata"]["namespace"] == "deployx"
    assert data["spec"]["type"] == "ClusterIP"
    assert data["spec"]["selector"] == {
        "app": "deployx-backend",
        "deployment-color": "blue",
    }
    assert data["spec"]["ports"][0]["port"] == 8000
    assert data["spec"]["ports"][0]["targetPort"] == "http"


def test_frontend_deployment_and_service() -> None:
    """Verify frontend Deployment and NodePort Service configurations."""
    content = (K8S_DIR / "frontend.yaml").read_text(encoding="utf-8")
    docs = list(yaml.safe_load_all(content))

    assert len(docs) == 2, "frontend.yaml must define Deployment and Service"
    deployment = docs[0]
    service = docs[1]

    # Deployment assertions
    assert deployment["kind"] == "Deployment"
    assert deployment["metadata"]["name"] == "deployx-frontend"
    assert deployment["metadata"]["namespace"] == "deployx"
    assert deployment["spec"]["replicas"] == 1

    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert container["name"] == "frontend"
    assert container["image"] == "deployx-frontend:latest"
    assert container["imagePullPolicy"] == "IfNotPresent"
    assert container["ports"][0]["containerPort"] == 80

    # Probes
    assert container["readinessProbe"]["httpGet"]["path"] == "/"
    assert container["livenessProbe"]["httpGet"]["path"] == "/"

    # Resource requests & limits
    assert container["resources"]["requests"]["cpu"] == "50m"
    assert container["resources"]["requests"]["memory"] == "32Mi"
    assert container["resources"]["limits"]["cpu"] == "250m"
    assert container["resources"]["limits"]["memory"] == "128Mi"

    # Service assertions
    assert service["kind"] == "Service"
    assert service["metadata"]["name"] == "deployx-frontend"
    assert service["metadata"]["namespace"] == "deployx"
    assert service["spec"]["type"] == "NodePort"
    assert service["spec"]["selector"] == {"app": "deployx-frontend"}
    assert service["spec"]["ports"][0]["port"] == 80
    assert service["spec"]["ports"][0]["targetPort"] == "http"
    assert service["spec"]["ports"][0]["nodePort"] == 30080
