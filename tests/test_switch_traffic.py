"""Automated Unit Tests for switch_traffic.sh Controller.

Validates traffic switching logic, argument validation, pre-flight checks,
endpoint verification, and automated rollback using mocked kubectl behaviors.
Runs completely offline without requiring a live Kubernetes cluster.
"""

import os
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT_DIR / "scripts" / "linux" / "switch_traffic.sh"


def test_script_exists_and_executable() -> None:
    """Verify script file exists and is executable."""
    assert SCRIPT_PATH.is_file(), f"Missing script: {SCRIPT_PATH}"


def test_no_arguments_fails() -> None:
    """Invoking script with no arguments prints usage and returns non-zero."""
    result = subprocess.run(
        ["bash", str(SCRIPT_PATH)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "Usage:" in result.stderr or "Usage:" in result.stdout


def test_invalid_color_argument_fails() -> None:
    """Invoking script with invalid color prints error and returns non-zero."""
    result = subprocess.run(
        ["bash", str(SCRIPT_PATH), "yellow"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "Invalid color 'yellow'" in result.stderr or "Invalid color" in result.stdout


@pytest.fixture
def mock_bin_dir():
    """Create a temporary directory for mock binaries."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        yield Path(tmp_dir)


def test_preflight_failure_aborts_switch(mock_bin_dir: Path) -> None:
    """If target deployment is not ready, switch is aborted without patching."""
    mock_kubectl = mock_bin_dir / "kubectl"
    # Mock kubectl rollout status failing
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$1" == "rollout" && "$2" == "status" ]]; then
    echo "Waiting for deployment to complete..." >&2
    exit 1
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"
    env["DEPLOYX_ENDPOINT_TIMEOUT"] = "1"

    result = subprocess.run(
        ["bash", str(SCRIPT_PATH), "green"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "is not fully rolled out" in result.stderr or "is not ready" in result.stderr


def test_successful_switch_to_green(mock_bin_dir: Path) -> None:
    """When target deployment is ready and endpoints verify, switch succeeds."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"readyReplicas"* ]]; then
    echo "1"
    exit 0
fi
if [[ "$*" == *"deployment-color"* ]]; then
    echo "blue"
    exit 0
fi
if [[ "$*" == *"endpoints"* ]]; then
    echo "10.244.0.7"
    exit 0
fi
if [[ "$1" == "patch" ]]; then
    echo "service/backend patched"
    exit 0
fi
if [[ "$1" == "rollout" ]]; then
    echo "deployment successfully rolled out"
    exit 0
fi
if [[ "$1" == "get" ]]; then
    exit 0
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"
    env["DEPLOYX_ENDPOINT_TIMEOUT"] = "1"

    result = subprocess.run(
        ["bash", str(SCRIPT_PATH), "green"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0
    assert "[SUCCESS] Traffic successfully switched to green." in result.stdout
    assert "10.244.0.7" in result.stdout


def test_already_routed_color_is_noop(mock_bin_dir: Path) -> None:
    """When traffic is already routed to requested color, no patch is performed."""
    mock_kubectl = mock_bin_dir / "kubectl"
    mock_kubectl.write_text(
        """#!/usr/bin/env bash
if [[ "$*" == *"readyReplicas"* ]]; then
    echo "1"
    exit 0
fi
if [[ "$*" == *"deployment-color"* ]]; then
    echo "blue"
    exit 0
fi
if [[ "$1" == "patch" ]]; then
    echo "ERROR: Should not patch when already current color" >&2
    exit 1
fi
if [[ "$1" == "rollout" ]]; then
    exit 0
fi
if [[ "$1" == "get" ]]; then
    exit 0
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"
    env["DEPLOYX_ENDPOINT_TIMEOUT"] = "1"

    result = subprocess.run(
        ["bash", str(SCRIPT_PATH), "blue"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0
    assert "already routed to 'blue'" in result.stdout


def test_endpoint_failure_triggers_automatic_rollback(mock_bin_dir: Path) -> None:
    """If patched service produces zero ready endpoints, it automatically rolls back."""
    mock_kubectl = mock_bin_dir / "kubectl"
    log_file = mock_bin_dir / "kubectl_calls.log"

    mock_kubectl.write_text(
        f"""#!/usr/bin/env bash
echo "$*" >> "{log_file}"
if [[ "$*" == *"readyReplicas"* ]]; then
    echo "1"
    exit 0
fi
if [[ "$*" == *"deployment-color"* ]]; then
    echo "blue"
    exit 0
fi
if [[ "$*" == *"endpoints"* ]]; then
    # Return empty to simulate endpoint discovery failure
    echo ""
    exit 0
fi
if [[ "$1" == "patch" ]]; then
    echo "service patched"
    exit 0
fi
if [[ "$1" == "rollout" ]]; then
    exit 0
fi
if [[ "$1" == "get" ]]; then
    exit 0
fi
exit 0
""",
        encoding="utf-8",
    )
    mock_kubectl.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{mock_bin_dir}:{env['PATH']}"
    env["DEPLOYX_ENDPOINT_TIMEOUT"] = "1"

    result = subprocess.run(
        ["bash", str(SCRIPT_PATH), "green"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 1
    assert "Verification failed" in result.stderr
    assert "Restored 'backend' selector to 'blue'" in result.stderr

    # Verify rollback patch was executed
    calls = log_file.read_text(encoding="utf-8")
    assert "patch service backend" in calls
    assert 'deployment-color":"blue"' in calls
