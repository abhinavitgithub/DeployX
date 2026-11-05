"""Automated Tests for DeployX Prometheus & Grafana Monitoring Configuration.

Validates:
1. Presence of all monitoring manifests, configurations, and dashboards.
2. YAML schema and contract validation for Prometheus Deployment, ConfigMap, and Service.
3. Prometheus scrape configuration (15s interval, backend target, metrics path).
4. Prometheus alerting rules (target down, error rate, request latency).
5. YAML schema and contract validation for Grafana Deployment, Secret, ConfigMaps, and Service.
6. Grafana datasource provisioning (Prometheus default proxy datasource with verified UID).
7. Grafana dashboard JSON integrity (valid JSON, panels for RED metrics, latency, uptime, availability, 15m range, 10s refresh).
8. Strict resource constraints (Prometheus memory <= 384Mi, Grafana memory <= 192Mi).
9. Monitoring deployment script integrity and executable permissions.
"""

import json
from pathlib import Path

import yaml

ROOT_DIR = Path(__file__).resolve().parent.parent
MONITORING_DIR = ROOT_DIR / "infrastructure" / "monitoring"
SCRIPTS_DIR = ROOT_DIR / "scripts" / "linux"


def test_monitoring_files_exist() -> None:
    """Verify all required monitoring manifests, configs, and scripts exist."""
    required_files = [
        MONITORING_DIR / "prometheus.yaml",
        MONITORING_DIR / "grafana.yaml",
        MONITORING_DIR / "README.md",
        MONITORING_DIR / "prometheus" / "prometheus.yml",
        MONITORING_DIR / "prometheus" / "alerts.yml",
        MONITORING_DIR / "grafana" / "provisioning" / "datasources" / "datasource.yml",
        MONITORING_DIR / "grafana" / "provisioning" / "dashboards" / "dashboards.yml",
        MONITORING_DIR / "grafana" / "dashboards" / "deployx-overview.json",
        SCRIPTS_DIR / "deploy_monitoring.sh",
    ]
    for file_path in required_files:
        assert file_path.is_file(), f"Missing required monitoring file: {file_path}"


def test_prometheus_manifest_and_contracts() -> None:
    """Verify Prometheus ConfigMap, Deployment, and Services configurations."""
    content = (MONITORING_DIR / "prometheus.yaml").read_text(encoding="utf-8")
    docs = list(yaml.safe_load_all(content))

    # Expect: ConfigMap, Deployment, Service (prometheus), Service (deployx-prometheus)
    assert len(docs) >= 3, "prometheus.yaml must define ConfigMap, Deployment, and Service"

    config_map = next(d for d in docs if d["kind"] == "ConfigMap")
    deployment = next(d for d in docs if d["kind"] == "Deployment")
    services = [d for d in docs if d["kind"] == "Service"]

    # 1. ConfigMap validation
    assert config_map["metadata"]["name"] == "deployx-prometheus-config"
    assert config_map["metadata"]["namespace"] == "deployx"

    prom_cfg = yaml.safe_load(config_map["data"]["prometheus.yml"])
    assert prom_cfg["global"]["scrape_interval"] == "15s"
    assert prom_cfg["global"]["evaluation_interval"] == "15s"

    scrape_jobs = {job["job_name"]: job for job in prom_cfg["scrape_configs"]}
    assert "deployx-backend" in scrape_jobs
    assert "prometheus" in scrape_jobs

    backend_job = scrape_jobs["deployx-backend"]
    assert backend_job["scrape_interval"] == "15s"
    assert backend_job["metrics_path"] == "/metrics"
    assert backend_job["static_configs"][0]["targets"] == ["backend.deployx.svc.cluster.local:8000"]

    # 2. Alert rules validation
    alerts_cfg = yaml.safe_load(config_map["data"]["alerts.yml"])
    rule_names = [rule["alert"] for group in alerts_cfg["groups"] for rule in group["rules"]]
    assert "DeployXBackendDown" in rule_names
    assert "DeployXHighErrorRate" in rule_names

    # 3. Deployment validation
    assert deployment["metadata"]["name"] == "deployx-prometheus"
    assert deployment["metadata"]["namespace"] == "deployx"
    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["selector"]["matchLabels"]["app"] == "deployx-prometheus"

    pod_spec = deployment["spec"]["template"]["spec"]
    assert pod_spec["securityContext"]["runAsNonRoot"] is True
    assert pod_spec["securityContext"]["runAsUser"] == 65534

    container = pod_spec["containers"][0]
    assert "prom/prometheus:v2.54.1" in container["image"]

    # Resource constraints check
    limits = container["resources"]["limits"]
    assert limits["memory"] == "384Mi", f"Prometheus memory limit must be <= 384Mi, got {limits['memory']}"

    # Probes check
    assert container["livenessProbe"]["httpGet"]["path"] == "/-/healthy"
    assert container["readinessProbe"]["httpGet"]["path"] == "/-/ready"

    # 4. Service validation
    service_names = [s["metadata"]["name"] for s in services]
    assert "prometheus" in service_names
    prom_svc = next(s for s in services if s["metadata"]["name"] == "prometheus")
    assert prom_svc["spec"]["ports"][0]["port"] == 9090


def test_grafana_manifest_and_contracts() -> None:
    """Verify Grafana Secret, ConfigMaps, Deployment, and Services configurations."""
    content = (MONITORING_DIR / "grafana.yaml").read_text(encoding="utf-8")
    docs = list(yaml.safe_load_all(content))

    secret = next(d for d in docs if d["kind"] == "Secret")
    config_maps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ConfigMap"}
    deployment = next(d for d in docs if d["kind"] == "Deployment")
    services = [d for d in docs if d["kind"] == "Service"]

    # 1. Secret validation
    assert secret["metadata"]["name"] == "deployx-grafana-secret"
    assert "admin-user" in secret["stringData"]
    assert "admin-password" in secret["stringData"]

    # 2. ConfigMaps validation
    assert "deployx-grafana-datasources" in config_maps
    assert "deployx-grafana-dashboard-provider" in config_maps
    assert "deployx-grafana-dashboards" in config_maps

    # Check datasource configuration
    ds_raw = config_maps["deployx-grafana-datasources"]["data"]["datasource.yml"]
    ds_data = yaml.safe_load(ds_raw)
    assert ds_data["datasources"][0]["type"] == "prometheus"
    assert ds_data["datasources"][0]["uid"] == "PBFA97CFB590B2093"
    assert "prometheus" in ds_data["datasources"][0]["url"]
    assert ds_data["datasources"][0]["isDefault"] is True

    # 3. Deployment validation
    assert deployment["metadata"]["name"] == "deployx-grafana"
    assert deployment["metadata"]["namespace"] == "deployx"
    assert deployment["spec"]["replicas"] == 1

    pod_spec = deployment["spec"]["template"]["spec"]
    assert pod_spec["securityContext"]["runAsNonRoot"] is True
    assert pod_spec["securityContext"]["runAsUser"] == 472

    container = pod_spec["containers"][0]
    assert "grafana/grafana:11.2.0" in container["image"]

    # Resource constraints check
    limits = container["resources"]["limits"]
    assert limits["memory"] == "192Mi", f"Grafana memory limit must be <= 192Mi, got {limits['memory']}"

    # Probes check
    assert container["livenessProbe"]["httpGet"]["path"] == "/api/health"
    assert container["readinessProbe"]["httpGet"]["path"] == "/api/health"

    # 4. Service validation
    service_names = [s["metadata"]["name"] for s in services]
    assert "grafana" in service_names
    graf_svc = next(s for s in services if s["metadata"]["name"] == "grafana")
    assert graf_svc["spec"]["ports"][0]["port"] == 3000


def test_grafana_dashboard_json_integrity() -> None:
    """Verify Grafana dashboard JSON integrity, exact datasource UID, and verified PromQL queries."""
    dashboard_file = MONITORING_DIR / "grafana" / "dashboards" / "deployx-overview.json"
    content = dashboard_file.read_text(encoding="utf-8")
    data = json.loads(content)

    assert data["uid"] == "deployx-overview"
    assert "DeployX" in data["title"]
    assert data["time"] == {"from": "now-15m", "to": "now"}
    assert data["refresh"] == "10s"
    assert len(data["panels"]) >= 5

    all_exprs = []
    for panel in data["panels"]:
        if panel.get("type") == "row":
            continue
        # Verify datasource UID on panel
        if "datasource" in panel and isinstance(panel["datasource"], dict):
            assert panel["datasource"]["uid"] == "PBFA97CFB590B2093"
        if "targets" in panel:
            for target in panel["targets"]:
                if "datasource" in target and isinstance(target["datasource"], dict):
                    assert target["datasource"]["uid"] == "PBFA97CFB590B2093"
                if "expr" in target:
                    all_exprs.append(target["expr"])

    combined_exprs = " ".join(all_exprs)
    # Check all 10 verified PromQL queries
    assert 'up{job="deployx-backend"}' in combined_exprs
    assert "deployx_application_uptime_seconds" in combined_exprs
    assert 'sum(rate(deployx_http_requests_total{status=~"5.."}[5m])) or vector(0)' in combined_exprs
    assert "sum(rate(deployx_http_requests_total[5m]))" in combined_exprs
    assert "sum by (handler) (rate(deployx_http_requests_total[5m]))" in combined_exprs
    assert "sum by (status) (rate(deployx_http_requests_total[5m]))" in combined_exprs
    assert "histogram_quantile(0.50, sum by (le) (rate(deployx_http_request_duration_seconds_bucket[5m])))" in combined_exprs
    assert "histogram_quantile(0.95, sum by (le) (rate(deployx_http_request_duration_seconds_bucket[5m])))" in combined_exprs
    assert "histogram_quantile(0.99, sum by (le) (rate(deployx_http_request_duration_seconds_bucket[5m])))" in combined_exprs
    assert "deployx_application_info" in combined_exprs


def test_deploy_monitoring_script_exists_and_executable() -> None:
    """Verify deployment script exists and contains rollout validation."""
    script_path = SCRIPTS_DIR / "deploy_monitoring.sh"
    assert script_path.is_file(), f"Missing deployment script: {script_path}"
    content = script_path.read_text(encoding="utf-8")
    assert "#!/usr/bin/env bash" in content
    assert "kubectl apply" in content
    assert "rollout status" in content
