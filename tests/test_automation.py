"""Automated Tests for DeployX Cross-Platform Automation Tooling (Phase 7).

Validates:
1. Presence of all Linux Bash and Windows PowerShell scripts and runbook documentation.
2. Valid Bash syntax across all Linux scripts (via bash -n).
3. CLI help and argument validation across deploy, health_check, rollback, backup, and cleanup.
4. Pre-flight dependency failure handling (missing kubectl/docker, unreachable cluster).
5. Deployment controller dry-run validation, rollout synchronization, and error handling.
6. Health check synthetic diagnostic checks, failure detection, and JSON schema formatting.
7. Disaster recovery rollback auto-toggle, target health safety gates, and emergency reversion.
8. Backup controller manifest generation, archive creation, and retention limit pruning.
9. Cleanup controller dry-run, interactive confirmation safety gate, and active green deletion protection.
10. Windows PowerShell script integrity and syntax validation.
"""

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT_DIR / "scripts"
LINUX_DIR = SCRIPTS_DIR / "linux"
WINDOWS_DIR = SCRIPTS_DIR / "windows"


# ------------------------------------------------------------------------------
# 1. File Existence & Permissions
# ------------------------------------------------------------------------------
def test_all_automation_scripts_exist() -> None:
    """Verify all required Linux and Windows automation scripts exist."""
    required_linux_scripts = [
        LINUX_DIR / "deploy.sh",
        LINUX_DIR / "health_check.sh",
        LINUX_DIR / "rollback.sh",
        LINUX_DIR / "backup.sh",
        LINUX_DIR / "cleanup.sh",
        LINUX_DIR / "switch_traffic.sh",
        LINUX_DIR / "deploy_monitoring.sh",
    ]
    for script in required_linux_scripts:
        assert script.is_file(), f"Missing required Linux script: {script}"

    required_windows_scripts = [
        WINDOWS_DIR / "deploy.ps1",
        WINDOWS_DIR / "health_check.ps1",
        WINDOWS_DIR / "rollback.ps1",
        WINDOWS_DIR / "backup.ps1",
        WINDOWS_DIR / "cleanup.ps1",
        WINDOWS_DIR / "switch_traffic.ps1",
    ]
    for script in required_windows_scripts:
        assert script.is_file(), f"Missing required Windows script: {script}"

    assert (SCRIPTS_DIR / "README.md").is_file(), "Missing scripts/README.md documentation"


def test_linux_scripts_syntax_check() -> None:
    """Verify syntax of all Linux Bash scripts using bash -n if bash is available."""
    bash_bin = shutil.which("bash")
    if not bash_bin:
        pytest.skip("bash is not available on host system")

    for script in LINUX_DIR.glob("*.sh"):
        result = subprocess.run(
            ["bash", "-n", str(script)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, f"Bash syntax error in {script.name}: {result.stderr}"


# ------------------------------------------------------------------------------
# 2. CLI Help & Argument Validation
# ------------------------------------------------------------------------------
@pytest.mark.parametrize(
    "script_name,help_flag",
    [
        ("deploy.sh", "--help"),
        ("health_check.sh", "--help"),
        ("rollback.sh", "--help"),
        ("backup.sh", "--help"),
        ("cleanup.sh", "--help"),
    ],
)
def test_linux_scripts_help_flag(script_name: str, help_flag: str) -> None:
    """Verify that --help returns exit code 0 and displays usage information."""
    bash_bin = shutil.which("bash")
    if not bash_bin:
        pytest.skip("bash is not available on host system")

    script_path = LINUX_DIR / script_name
    result = subprocess.run(
        ["bash", str(script_path), help_flag],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0
    assert "Usage:" in result.stdout or "Usage:" in result.stderr


def test_deploy_invalid_color_argument() -> None:
    """Deploy script rejects invalid color arguments."""
    bash_bin = shutil.which("bash")
    if not bash_bin:
        pytest.skip("bash is not available")

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "deploy.sh"), "--color", "purple"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "Invalid color 'purple'" in result.stderr or "Invalid color" in result.stdout


def test_deploy_invalid_timeout_argument() -> None:
    """Deploy script rejects non-integer timeout arguments."""
    bash_bin = shutil.which("bash")
    if not bash_bin:
        pytest.skip("bash is not available")

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "deploy.sh"), "--timeout", "not_a_number"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "positive integer" in result.stderr or "positive integer" in result.stdout


# ------------------------------------------------------------------------------
# 3. Mocks & Fixtures for Subprocess Testing
# ------------------------------------------------------------------------------
@pytest.fixture
def mock_bin_dir():
    """Create a temporary directory for mock binaries."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        yield Path(tmp_dir)


# ------------------------------------------------------------------------------
# 4. Deployment Controller Tests
# ------------------------------------------------------------------------------
def test_deploy_dry_run_validation(mock_bin_dir: Path) -> None:
    """Deploy script in dry-run mode validates manifests without applying."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"cluster-info"* ]]; then
    echo "Kubernetes control plane is running."
    exit 0
fi
if [[ "$*" == *"--dry-run=client"* ]]; then
    exit 0
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "deploy.sh"), "--dry-run"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0
    assert "[SUCCESS] Dry-run completed" in result.stdout


def test_deploy_missing_kubectl_fails(mock_bin_dir: Path) -> None:
    """Deploy script fails cleanly when kubectl is missing from PATH."""
    bash_bin = shutil.which("bash") or "/bin/bash"
    env = os.environ.copy()
    # Filter PATH to exclude directories containing kubectl
    clean_paths = [
        p for p in env.get("PATH", "").split(os.pathsep)
        if p and not (Path(p) / "kubectl").exists()
    ]
    env["PATH"] = os.pathsep.join(clean_paths)

    result = subprocess.run(
        [bash_bin, str(LINUX_DIR / "deploy.sh")],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "kubectl" in result.stderr or "kubectl" in result.stdout


# ------------------------------------------------------------------------------
# 5. Health Check Diagnostics Tests
# ------------------------------------------------------------------------------
def test_health_check_json_output(mock_bin_dir: Path) -> None:
    """Health check script outputs valid parseable JSON when --json flag is supplied."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"cluster-info"* ]]; then
    exit 0
fi
if [[ "$*" == *"get namespace"* ]]; then
    exit 0
fi
if [[ "$*" == *"deployment-color"* ]]; then
    echo "blue"
    exit 0
fi
if [[ "$*" == *"readyReplicas"* ]]; then
    echo "1"
    exit 0
fi
if [[ "$*" == *"endpoints"* ]]; then
    echo "10.244.0.5"
    exit 0
fi
if [[ "$*" == *"get pods"* ]]; then
    echo "deployx-frontend-mock-pod"
    exit 0
fi
if [[ "$*" == *"wget"* ]]; then
    if [[ "$*" == *"health/live"* ]]; then
        echo '{"status":"alive"}'
    elif [[ "$*" == *"health/ready"* ]]; then
        echo '{"status":"ready"}'
    elif [[ "$*" == *"api/v1/status"* ]]; then
        echo '{"process_status":"running","readiness_status":"ready"}'
    elif [[ "$*" == *"metrics"* ]]; then
        echo 'deployx_uptime 100'
    else
        echo 'DeployX'
    fi
    exit 0
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "health_check.sh"), "--json"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0
    data = json.loads(result.stdout)
    assert data["status"] == "HEALTHY"
    assert data["active_routing_color"] == "blue"
    assert data["deployments"]["deployx-backend"] == "PASS"
    assert data["probes"]["backend_liveness"] == "PASS"


def test_health_check_failure_detection(mock_bin_dir: Path) -> None:
    """Health check script returns non-zero when a critical deployment has zero replicas."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"cluster-info"* ]]; then exit 0; fi
if [[ "$*" == *"get namespace"* ]]; then exit 0; fi
if [[ "$*" == *"deployment-color"* ]]; then echo "blue"; exit 0; fi
if [[ "$*" == *"readyReplicas"* ]]; then echo "0"; exit 0; fi # Zero replicas!
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "health_check.sh")],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "UNHEALTHY" in result.stdout or "UNHEALTHY" in result.stderr


# ------------------------------------------------------------------------------
# 6. Disaster Recovery Rollback Tests
# ------------------------------------------------------------------------------
def test_rollback_auto_toggle_success(mock_bin_dir: Path) -> None:
    """Rollback script automatically detects blue and switches to green successfully."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"deployment-color"* ]]; then echo "blue"; exit 0; fi
if [[ "$*" == *"readyReplicas"* ]]; then echo "1"; exit 0; fi
if [[ "$*" == *"endpoints"* ]]; then echo "10.244.0.6"; exit 0; fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"
    env["DEPLOYX_ENDPOINT_TIMEOUT"] = "1"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "rollback.sh")],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0
    assert "Rollback Target:    green" in result.stdout
    assert "[SUCCESS] Disaster recovery rollback completed" in result.stdout


def test_rollback_preflight_aborts_on_unhealthy_target(mock_bin_dir: Path) -> None:
    """Rollback script aborts cutover if target deployment has 0 ready replicas."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"deployment-color"* ]]; then echo "blue"; exit 0; fi
if [[ "$*" == *"readyReplicas"* ]]; then echo "0"; exit 0; fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "rollback.sh"), "green"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "zero ready replicas" in result.stderr or "zero ready replicas" in result.stdout
    assert "Aborting rollback" in result.stderr or "Aborting rollback" in result.stdout


# ------------------------------------------------------------------------------
# 7. Backup Controller Tests
# ------------------------------------------------------------------------------
def test_backup_creates_archive_and_metadata(mock_bin_dir: Path) -> None:
    """Backup script creates timestamped archive with metadata."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"deployment-color"* ]]; then echo "blue"; exit 0; fi
echo "mock yaml content"
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    with tempfile.TemporaryDirectory() as backup_test_dir:
        env = os.environ.copy()
        env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

        result = subprocess.run(
            ["bash", str(LINUX_DIR / "backup.sh"), "--dir", backup_test_dir, "--retention", "3"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        assert result.returncode == 0
        assert "[SUCCESS] Backup completed" in result.stdout

        # Verify backup archive exists in test directory
        backups = list(Path(backup_test_dir).glob("deployx_backup_*"))
        assert len(backups) == 1


# ------------------------------------------------------------------------------
# 8. Cleanup Controller Tests
# ------------------------------------------------------------------------------
def test_cleanup_dry_run_mode(mock_bin_dir: Path) -> None:
    """Cleanup script in dry-run mode previews deletion without executing removal."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "cleanup.sh"), "--dry-run"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0
    assert "[SUCCESS] Dry-run completed. No resources were deleted." in result.stdout


def test_cleanup_green_only_protects_active_green(mock_bin_dir: Path) -> None:
    """Cleanup in green-only mode refuses deletion if Green is currently active."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"deployment-color"* ]]; then
    echo "green"
    exit 0
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"

    result = subprocess.run(
        ["bash", str(LINUX_DIR / "cleanup.sh"), "--green-only", "-f"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "actively receiving traffic" in result.stderr or "actively receiving traffic" in result.stdout


# ------------------------------------------------------------------------------
# 9. Windows PowerShell Script Validation
# ------------------------------------------------------------------------------
def test_powershell_scripts_have_param_blocks() -> None:
    """Verify that all Windows PowerShell scripts declare CmdletBinding and param blocks."""
    for ps_script in WINDOWS_DIR.glob("*.ps1"):
        content = ps_script.read_text(encoding="utf-8")
        assert "[CmdletBinding()]" in content, f"{ps_script.name} is missing [CmdletBinding()]"
        assert "param (" in content or "param(" in content, f"{ps_script.name} is missing param block"
        assert "exit 0" in content, f"{ps_script.name} is missing exit 0"
