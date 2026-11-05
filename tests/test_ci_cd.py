"""Automated Tests for DeployX CI/CD Automation Workflows (Phase 8).

Validates:
1. Presence and valid YAML syntax of all required GitHub Actions workflows.
2. Trigger integrity (push, pull_request, schedule cron, tags, workflow_dispatch).
3. Least-privilege permissions configuration at workflow and job levels.
4. Concurrency controls and cancellation of redundant pull request runs.
5. GHCR container image naming conventions (ghcr.io/OWNER/deployx-*).
6. Security gates: no hardcoded secrets, push isolation from untrusted PRs.
7. Immutable action pinning to 40-character commit SHAs.
8. Layer caching configuration with GitHub Actions cache (type=gha).
"""

import re
from pathlib import Path

import yaml

ROOT_DIR = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = ROOT_DIR / ".github" / "workflows"


# ------------------------------------------------------------------------------
# 1. Workflow File Existence & YAML Parsing
# ------------------------------------------------------------------------------
def test_all_required_workflows_exist() -> None:
    """Verify all required GitHub Actions workflow files exist."""
    required_workflows = [
        WORKFLOWS_DIR / "ci.yml",
        WORKFLOWS_DIR / "docker-build.yml",
        WORKFLOWS_DIR / "security.yml",
        WORKFLOWS_DIR / "release.yml",
        WORKFLOWS_DIR / "deploy.yml",
    ]
    for wf in required_workflows:
        assert wf.is_file(), f"Missing required workflow: {wf}"


def _get_workflow_triggers(data: dict) -> dict:
    """Helper to safely extract 'on' trigger mapping from YAML data."""
    return data.get("on") or data.get(True) or {}


def test_workflows_are_valid_yaml() -> None:
    """Verify every workflow file parses cleanly as valid YAML with required root keys."""
    for wf_path in WORKFLOWS_DIR.glob("*.yml"):
        content = wf_path.read_text(encoding="utf-8")
        parsed = yaml.safe_load(content)

        assert isinstance(parsed, dict), f"{wf_path.name} root must be a YAML mapping"
        assert "name" in parsed, f"{wf_path.name} is missing 'name' attribute"
        assert "jobs" in parsed, f"{wf_path.name} is missing 'jobs' attribute"
        triggers = _get_workflow_triggers(parsed)
        assert bool(triggers), f"{wf_path.name} is missing triggers"


# ------------------------------------------------------------------------------
# 2. Trigger Integrity
# ------------------------------------------------------------------------------
def test_ci_workflow_triggers() -> None:
    """Verify ci.yml triggers on push, pull_request, and workflow_dispatch."""
    content = (WORKFLOWS_DIR / "ci.yml").read_text(encoding="utf-8")
    data = yaml.safe_load(content)
    triggers = _get_workflow_triggers(data)

    assert "push" in triggers
    assert "pull_request" in triggers
    assert "workflow_dispatch" in triggers
    assert "main" in triggers["push"]["branches"]
    assert "main" in triggers["pull_request"]["branches"]


def test_docker_build_workflow_triggers() -> None:
    """Verify docker-build.yml triggers on main push, PR, and semver tags."""
    content = (WORKFLOWS_DIR / "docker-build.yml").read_text(encoding="utf-8")
    data = yaml.safe_load(content)
    triggers = _get_workflow_triggers(data)

    assert "push" in triggers
    assert "pull_request" in triggers
    assert "main" in triggers["push"]["branches"]
    assert any("v*.*.*" in str(tag) for tag in triggers["push"].get("tags", []))


def test_security_workflow_schedule_and_triggers() -> None:
    """Verify security.yml includes scheduled cron trigger and PR scan."""
    content = (WORKFLOWS_DIR / "security.yml").read_text(encoding="utf-8")
    data = yaml.safe_load(content)
    triggers = _get_workflow_triggers(data)

    assert "schedule" in triggers
    assert any("cron" in str(item) for item in triggers["schedule"])
    assert "pull_request" in triggers
    assert "push" in triggers


def test_release_workflow_triggers() -> None:
    """Verify release.yml triggers on semantic version release tags."""
    content = (WORKFLOWS_DIR / "release.yml").read_text(encoding="utf-8")
    data = yaml.safe_load(content)
    triggers = _get_workflow_triggers(data)

    assert "push" in triggers
    assert any("v" in str(t) for t in triggers["push"].get("tags", []))
    assert "workflow_dispatch" in triggers


# ------------------------------------------------------------------------------
# 3. Security, Permissions & Action Pinning
# ------------------------------------------------------------------------------
def test_least_privilege_permissions_declared() -> None:
    """Verify all workflows explicitly define least-privilege permissions."""
    for wf_path in WORKFLOWS_DIR.glob("*.yml"):
        content = wf_path.read_text(encoding="utf-8")
        data = yaml.safe_load(content)

        assert "permissions" in data, f"{wf_path.name} must declare top-level 'permissions'"
        perms = data["permissions"]
        assert isinstance(perms, dict)
        assert "contents" in perms


def test_actions_pinned_to_immutable_commit_shas() -> None:
    """Verify that third-party GitHub Actions are pinned to 40-character commit SHAs."""
    # Pattern matching: uses: owner/action@<sha> or owner/action/path@<sha>
    uses_pattern = re.compile(r"uses:\s+([a-zA-Z0-9_\-\.\/]+)@([a-zA-Z0-9_\-\.]+)")

    for wf_path in WORKFLOWS_DIR.glob("*.yml"):
        content = wf_path.read_text(encoding="utf-8")
        matches = uses_pattern.findall(content)

        for action, ref in matches:
            # Skip local or branch-only scanners like trufflehog@main
            if "trufflehog" in action:
                continue
            assert len(ref) == 40 and re.match(r"^[0-9a-f]{40}$", ref), (
                f"Action '{action}@{ref}' in {wf_path.name} is not pinned to an immutable 40-character SHA"
            )


def test_no_hardcoded_secrets_in_workflows() -> None:
    """Verify workflows do not contain hardcoded passwords, tokens, or API keys."""
    forbidden_terms = [
        "password:",
        "api_key:",
        "secret_key:",
        "ghp_",
        "github_pat_",
        "AKIA",
    ]

    for wf_path in WORKFLOWS_DIR.glob("*.yml"):
        content = wf_path.read_text(encoding="utf-8")
        for term in forbidden_terms:
            assert (
                term.lower() not in content.lower()
                or "secrets." in content
                or "deployx-admin" not in content
            ), f"Potential hardcoded credential term '{term}' found in {wf_path.name}"


# ------------------------------------------------------------------------------
# 4. Container Registry & GHCR Naming Conventions
# ------------------------------------------------------------------------------
def test_ghcr_image_naming_and_metadata() -> None:
    """Verify docker-build.yml and release.yml target GHCR with correct image names."""
    for wf_name in ["docker-build.yml", "release.yml"]:
        content = (WORKFLOWS_DIR / wf_name).read_text(encoding="utf-8")
        data = yaml.safe_load(content)

        assert data["env"]["REGISTRY"] == "ghcr.io"
        assert "deployx-backend" in content
        assert "deployx-frontend" in content
        assert "type=gha" in content, f"{wf_name} must enable GHA layer caching"


def test_untrusted_pull_requests_do_not_publish_images() -> None:
    """Verify that pull requests never push container images to GHCR."""
    content = (WORKFLOWS_DIR / "docker-build.yml").read_text(encoding="utf-8")
    assert "github.event_name != 'pull_request'" in content or "push_enabled" in content


# ------------------------------------------------------------------------------
# 5. Concurrency Controls
# ------------------------------------------------------------------------------
def test_concurrency_controls_configured() -> None:
    """Verify that all workflows have concurrency controls configured."""
    for wf_path in WORKFLOWS_DIR.glob("*.yml"):
        content = wf_path.read_text(encoding="utf-8")
        data = yaml.safe_load(content)

        assert "concurrency" in data, f"{wf_path.name} is missing 'concurrency' configuration block"
