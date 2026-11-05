# DeployX Automation Tooling (Phase 7)

Reliable, reusable, cross-platform automation tooling for DeployX deployment, health verification, disaster recovery rollback, cluster backup, and environment teardown.

All scripts provide feature parity between **Linux (Bash)** and **Windows (PowerShell)**, incorporating strict error handling, pre-flight safety gates, automated rollback on endpoint failure, configurable environment variables, and persistent audit logging.

---

## Directory Structure

```text
scripts/
├── README.md                      # This documentation
├── run_all_tests.sh               # Master test runner
├── linux/                         # Linux Bash automation suite
│   ├── deploy.sh                  # Multi-tier deployment controller
│   ├── health_check.sh            # Cluster health & synthetic probe diagnostics
│   ├── rollback.sh                # Disaster recovery rollback controller
│   ├── backup.sh                  # Cluster state & configuration backup
│   ├── cleanup.sh                 # Tiered resource cleanup & teardown
│   ├── switch_traffic.sh          # Blue-Green traffic switching controller
│   └── deploy_monitoring.sh       # Prometheus & Grafana stack deployment
└── windows/                       # Windows PowerShell automation suite
    ├── deploy.ps1                 # Multi-tier deployment controller
    ├── health_check.ps1           # Cluster health & synthetic probe diagnostics
    ├── rollback.ps1               # Disaster recovery rollback controller
    ├── backup.ps1                 # Cluster state & configuration backup
    ├── cleanup.ps1                # Tiered resource cleanup & teardown
    └── switch_traffic.ps1         # Blue-Green traffic switching controller
```

---

## Core Tooling Reference

### 1. Deployment Controller (`deploy.sh` / `deploy.ps1`)
Orchestrates manifest validation, multi-tier deployment rollout, and post-deployment health verification.

- **Pre-flight Checks:** Verifies `kubectl` and `docker` CLI availability, cluster connectivity (`cluster-info`).
- **Dry-run Validation:** Validates all Kubernetes manifests client-side before applying.
- **Rollout Synchronization:** Waits for full rollout completion (`deployx-backend`, `deployx-backend-green`, `deployx-frontend`, and optionally monitoring).
- **Post-deployment Verification:** Automatically triggers synthetic health probes.

#### Usage (Linux):
```bash
# Standard Blue-Green deployment (default: Blue active)
./scripts/linux/deploy.sh

# Deploy with Prometheus and Grafana monitoring (Phase 6)
./scripts/linux/deploy.sh --include-monitoring

# Dry-run validation only (does not modify cluster)
./scripts/linux/deploy.sh --dry-run

# Custom namespace and initial active routing color
./scripts/linux/deploy.sh --namespace deployx --color green --timeout 90
```

#### Usage (Windows):
```powershell
# Standard deployment
.\scripts\windows\deploy.ps1

# Include monitoring stack
.\scripts\windows\deploy.ps1 -IncludeMonitoring

# Dry-run validation
.\scripts\windows\deploy.ps1 -DryRun

# Custom color and timeout
.\scripts\windows\deploy.ps1 -Color green -Timeout 90
```

---

### 2. Health Verification & Diagnostics (`health_check.sh` / `health_check.ps1`)
Performs multi-layer diagnostics across Kubernetes pods, services, endpoints, and executes synthetic HTTP probes.

- **Pod Inspections:** Validates ready replicas ($\ge 1$) and identifies crashloops or restart anomalies.
- **Active Routing:** Identifies current active color on service `backend` (`blue` or `green`).
- **Synthetic HTTP Probes:**
  - Backend Liveness (`/health/live`)
  - Backend Readiness (`/health/ready`)
  - System Status (`/api/v1/status`)
  - Prometheus Metrics (`/metrics`)
  - Frontend Static Serving (`port 80`)
  - Monitoring Health (`prometheus:9090/-/healthy` and `grafana:3000/api/health`)
- **Machine-Readable Output:** Generates structured JSON via `--json` / `-Json`.

#### Usage (Linux):
```bash
# Standard health check
./scripts/linux/health_check.sh

# Include Prometheus and Grafana in critical evaluation
./scripts/linux/health_check.sh --include-monitoring

# Output diagnostic summary in JSON
./scripts/linux/health_check.sh --json
```

#### Usage (Windows):
```powershell
# Standard health check
.\scripts\windows\health_check.ps1

# Include monitoring
.\scripts\windows\health_check.ps1 -IncludeMonitoring

# JSON output
.\scripts\windows\health_check.ps1 -Json
```

---

### 3. Disaster Recovery Rollback (`rollback.sh` / `rollback.ps1`)
Safely rolls back active traffic to the alternate or specified deployment environment.

- **Auto-Toggle Detection:** Queries active service selector. If `blue`, targets `green`; if `green`, targets `blue`.
- **Pre-Flight Safety Gate:** Probes target deployment readiness. **Aborts immediately** if target deployment has zero ready replicas, preventing traffic cutover to unhealthy pods.
- **Automated Emergency Reversion:** If post-switch endpoint verification fails within timeout, immediately reverts the service selector back to the previous known-good deployment.
- **Audit Logging:** Logs all rollback events and outcomes to `data/deployx_operations.log`.

#### Usage (Linux):
```bash
# Auto-detect current active color and roll back to alternate
./scripts/linux/rollback.sh

# Explicit rollback to Blue
./scripts/linux/rollback.sh blue

# Explicit switch to Green with custom timeout
./scripts/linux/rollback.sh green --timeout 20
```

#### Usage (Windows):
```powershell
# Auto-toggle rollback
.\scripts\windows\rollback.ps1

# Explicit rollback to Blue
.\scripts\windows\rollback.ps1 -Color blue

# Explicit switch to Green
.\scripts\windows\rollback.ps1 -Color green -Timeout 20
```

---

### 4. Cluster Backup Controller (`backup.sh` / `backup.ps1`)
Captures complete cluster state, manifests, runtime metadata, and active routing into timestamped archives.

- **Captured Resources:** Namespace, Deployments, Services, ConfigMaps, Secrets, Pod inventories.
- **Metadata Captured:** Git commit SHA, branch, UTC timestamp, active Blue-Green routing color.
- **Archive Format:** `.tar.gz` on Linux, `.zip` on Windows.
- **Retention Management:** Automatically cleans up older backup archives when count exceeds retention limit (default: 5).

#### Usage (Linux):
```bash
# Create standard backup in backups/
./scripts/linux/backup.sh

# Custom retention limit and backup path
./scripts/linux/backup.sh --dir /tmp/deployx-backups --retention 10
```

#### Usage (Windows):
```powershell
# Create standard backup
.\scripts\windows\backup.ps1

# Custom directory and retention
.\scripts\windows\backup.ps1 -Dir C:\backups -Retention 10
```

---

### 5. Cluster Cleanup & Teardown (`cleanup.sh` / `cleanup.ps1`)
Provides controlled, tiered teardown of cluster resources.

- **Modes:**
  - `--all` (default): Deletes entire `deployx` namespace and all enclosed resources.
  - `--monitoring-only`: Deletes Prometheus and Grafana stack, preserving backend and frontend.
  - `--green-only`: Deletes inactive `deployx-backend-green` deployment to reclaim memory. Enforces safety check: **refuses deletion** if Green is currently active!
- **Safety Confirmations:** Interactive confirmation required unless `--force` / `-Force` is supplied.
- **Dry-run Mode:** Preview targeted resources without deletion.

#### Usage (Linux):
```bash
# Dry-run preview of complete teardown
./scripts/linux/cleanup.sh --dry-run

# Interactive complete teardown
./scripts/linux/cleanup.sh --all

# Non-interactive complete teardown
./scripts/linux/cleanup.sh --all -y

# Remove monitoring stack only
./scripts/linux/cleanup.sh --monitoring-only -y

# Remove Green deployment safely (reclaims ~128MiB RAM)
./scripts/linux/cleanup.sh --green-only -y
```

#### Usage (Windows):
```powershell
# Dry-run preview
.\scripts\windows\cleanup.ps1 -DryRun

# Non-interactive teardown
.\scripts\windows\cleanup.ps1 -All -Force

# Remove monitoring stack only
.\scripts\windows\cleanup.ps1 -MonitoringOnly -Force

# Remove Green deployment safely
.\scripts\windows\cleanup.ps1 -GreenOnly -Force
```

---

## Configuration & Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DEPLOYX_NAMESPACE` | `deployx` | Target Kubernetes namespace |
| `DEPLOYX_BACKEND_SERVICE` | `backend` | Name of the active routing Service |
| `DEPLOYX_TIMEOUT` | `60` | Rollout synchronization timeout in seconds |
| `DEPLOYX_ENDPOINT_TIMEOUT` | `15` | Active endpoint polling timeout in seconds |
| `DEPLOYX_PROBE_TIMEOUT` | `10` | Synthetic HTTP probe timeout in seconds |
| `DEPLOYX_LOG_FILE` | `data/deployx_operations.log` | Persistent operational audit log path |
| `DEPLOYX_BACKUP_DIR` | `backups` | Output directory for backup archives |
| `DEPLOYX_BACKUP_RETENTION` | `5` | Maximum number of backup archives to retain |
| `DEPLOYX_INCLUDE_MONITORING` | `false` | Enable monitoring stack in deployment & checks |

---

## Exit Code Conventions

| Exit Code | Meaning |
|:---:|---|
| `0` | Success / All health checks passed / Verified |
| `1` | Error / Rollout failure / Probe failure / Target deployment unhealthy |
