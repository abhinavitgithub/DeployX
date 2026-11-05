<#
.SYNOPSIS
    DeployX — Production Kubernetes Deployment Controller (PowerShell)
    Automates manifest validation, multi-tier deployment, rollout synchronization,
    and post-deployment health verification on Kubernetes.

.DESCRIPTION
    Validates cluster connectivity, executes client-side dry-run validation,
    applies Kubernetes manifests (core Blue-Green stack + optional Phase 6 monitoring),
    synchronizes rollout completion, and invokes health checks.

.PARAMETER IncludeMonitoring
    Deploys Prometheus and Grafana monitoring stack (Phase 6).

.PARAMETER DryRun
    Validates all manifests client-side without applying.

.PARAMETER Color
    Initial active routing color for service 'backend' (blue or green). Default: blue.

.PARAMETER Timeout
    Rollout wait timeout per deployment in seconds. Default: 60.

.PARAMETER Namespace
    Target Kubernetes namespace. Default: deployx.

.PARAMETER SkipHealthCheck
    Skips post-deployment synthetic health verification.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -IncludeMonitoring
    .\deploy.ps1 -DryRun
    .\deploy.ps1 -Color green -Timeout 90
#>

[CmdletBinding()]
param (
    [switch]$IncludeMonitoring,
    [switch]$DryRun,
    [ValidateSet("blue", "green")]
    [string]$Color = "blue",
    [int]$Timeout = 60,
    [string]$Namespace = "deployx",
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------------------------
# 1. Defaults & Configuration
# ------------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$K8sDir = Join-Path $RootDir "infrastructure\kubernetes"
$MonitoringDir = Join-Path $RootDir "infrastructure\monitoring"

if ($env:DEPLOYX_NAMESPACE) { $Namespace = $env:DEPLOYX_NAMESPACE }
if ($env:DEPLOYX_TIMEOUT) { $Timeout = [int]$env:DEPLOYX_TIMEOUT }
if ($env:DEPLOYX_INCLUDE_MONITORING -eq "true") { $IncludeMonitoring = $true }

$LogFile = if ($env:DEPLOYX_LOG_FILE) { $env:DEPLOYX_LOG_FILE } else { Join-Path $RootDir "data\deployx_operations.log" }

function Write-Log {
    param (
        [string]$Level,
        [string]$Message
    )
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$Timestamp] [$Level] $Message"
    try {
        $LogDir = Split-Path -Parent $LogFile
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        "[$Timestamp] [$Level] [deploy.ps1] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch { }
}

function Get-KubeResourceJson {
    param ([string]$Command)
    try {
        $raw = Invoke-Expression $Command 2>&1
        $clean = ($raw | Where-Object { $_ -notmatch '^\s*Warning:' -and $_ -notmatch '^\s*Defaulted container' }) -join "`n"
        if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
        return ($clean | ConvertFrom-Json)
    } catch {
        return $null
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "==> [DeployX] Executing Windows PowerShell Deployment Pipeline" -ForegroundColor Cyan
Write-Host "    Namespace:          $Namespace"
Write-Host "    Active Color:       $Color"
Write-Host "    Include Monitoring: $IncludeMonitoring"
Write-Host "    Dry Run Mode:       $DryRun"
Write-Host "    Rollout Timeout:    $($Timeout)s"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "INFO" "Starting deployment pipeline: namespace=$Namespace color=$Color monitoring=$IncludeMonitoring dry_run=$DryRun"

# ------------------------------------------------------------------------------
# 2. Pre-Flight Dependency & Connectivity Checks
# ------------------------------------------------------------------------------
Write-Host "==> [Pre-flight] Checking CLI tool availability..." -ForegroundColor Yellow

$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlCmd) {
    Write-Error "Error: 'kubectl' command not found in PATH. Please install kubectl."
    Write-Log "ERROR" "Pre-flight failed: kubectl not found in PATH"
    exit 1
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "Warning: 'docker' CLI not found in PATH. Continuing with kubectl only." -ForegroundColor DarkYellow
}

Write-Host "==> [Pre-flight] Verifying Kubernetes cluster connectivity..." -ForegroundColor Yellow
$clusterInfo = kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Cannot connect to Kubernetes cluster. Ensure cluster is running and KUBECONFIG is valid."
    Write-Log "ERROR" "Pre-flight failed: Cannot connect to Kubernetes cluster"
    exit 1
}
Write-Host "    Cluster is connected and responsive." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Manifest Validation (Dry-Run)
# ------------------------------------------------------------------------------
$ManifestFiles = @(
    (Join-Path $K8sDir "namespace.yaml"),
    (Join-Path $K8sDir "backend.yaml"),
    (Join-Path $K8sDir "backend-green.yaml"),
    (Join-Path $K8sDir "backend-alias.yaml"),
    (Join-Path $K8sDir "frontend.yaml")
)

if ($IncludeMonitoring) {
    $ManifestFiles += (Join-Path $MonitoringDir "prometheus.yaml")
    $ManifestFiles += (Join-Path $MonitoringDir "grafana.yaml")
}

Write-Host "==> [Validation] Validating manifests (client-side dry-run)..." -ForegroundColor Yellow
foreach ($manifest in $ManifestFiles) {
    if (-not (Test-Path $manifest)) {
        Write-Error "Error: Required manifest file not found: $manifest"
        Write-Log "ERROR" "Manifest missing: $manifest"
        exit 1
    }
    $valOut = kubectl apply --dry-run=client -f $manifest 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error: Manifest validation failed for: $manifest"
        Write-Log "ERROR" "Validation failed: $manifest"
        exit 1
    }
    Write-Host "    [VALID] $(Split-Path -Leaf $manifest)" -ForegroundColor Green
}

if ($DryRun) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "[SUCCESS] Dry-run completed. All manifests validated successfully." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Log "INFO" "Dry-run validation successful. No changes made."
    exit 0
}

# ------------------------------------------------------------------------------
# 4. Apply Kubernetes Manifests
# ------------------------------------------------------------------------------
Write-Host "==> [Deploy] Applying namespace manifest..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $K8sDir "namespace.yaml")

Write-Host "==> [Deploy] Applying backend Blue and Green deployments..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $K8sDir "backend.yaml")
kubectl apply -f (Join-Path $K8sDir "backend-green.yaml")

Write-Host "==> [Deploy] Configuring backend routing service to '$Color'..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $K8sDir "backend-alias.yaml")
if ($Color -eq "green") {
    $patch = '{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"green\"}}}'
    kubectl patch service backend -n $Namespace --type=merge -p $patch
}

Write-Host "==> [Deploy] Applying frontend deployment & service..." -ForegroundColor Yellow
kubectl apply -f (Join-Path $K8sDir "frontend.yaml")

if ($IncludeMonitoring) {
    Write-Host "==> [Deploy] Applying Phase 6 Prometheus & Grafana monitoring stack..." -ForegroundColor Yellow
    kubectl apply -f (Join-Path $MonitoringDir "prometheus.yaml")
    kubectl apply -f (Join-Path $MonitoringDir "grafana.yaml")
}

# ------------------------------------------------------------------------------
# 5. Wait for Rollout Completion
# ------------------------------------------------------------------------------
Write-Host "==> [Rollout] Synchronizing deployment rollouts (timeout: $($Timeout)s)..." -ForegroundColor Yellow

$Deployments = @("deployx-backend", "deployx-backend-green", "deployx-frontend")
if ($IncludeMonitoring) {
    $Deployments += @("deployx-prometheus", "deployx-grafana")
}

foreach ($dep in $Deployments) {
    Write-Host "    Waiting for rollout of '$dep'..."
    kubectl rollout status "deployment/$dep" -n $Namespace --timeout="$($Timeout)s"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error: Rollout failed or timed out for deployment '$dep'."
        Write-Log "ERROR" "Deployment rollout failed for '$dep' in namespace '$Namespace'"
        exit 1
    }
    $depObj = Get-KubeResourceJson "kubectl get deployment $dep -n $Namespace -o json"
    $readyReplicas = if ($null -ne $depObj -and $null -ne $depObj.status) { $depObj.status.readyReplicas } else { "0" }
    if ([string]::IsNullOrWhiteSpace($readyReplicas) -or [int]$readyReplicas -lt 1) {
        Write-Error "Error: Deployment '$dep' has zero ready replicas."
        Write-Log "ERROR" "Deployment '$dep' ready replicas check failed"
        exit 1
    }
}
Write-Log "INFO" "All deployments rolled out successfully: $($Deployments -join ', ')"

# ------------------------------------------------------------------------------
# 6. Post-Deployment Health Verification
# ------------------------------------------------------------------------------
if (-not $SkipHealthCheck) {
    Write-Host "==> [Verification] Running post-deployment health verification..." -ForegroundColor Yellow
    $HealthScript = Join-Path $ScriptDir "health_check.ps1"
    if (Test-Path $HealthScript) {
        $HealthArgs = @()
        if ($IncludeMonitoring) { $HealthArgs += "-IncludeMonitoring" }
        & $HealthScript @HealthArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Error: Post-deployment health verification reported failures."
            Write-Log "ERROR" "Post-deployment health check reported failure"
            exit 1
        }
    } else {
        Write-Host "    Health check script not found at $HealthScript. Verifying basic endpoints..."
        $backendEp = (kubectl get endpoints backend -n $Namespace -o jsonpath='{.subsets[*].addresses[*].ip}' 2>$null)
        $frontendEp = (kubectl get endpoints deployx-frontend -n $Namespace -o jsonpath='{.subsets[*].addresses[*].ip}' 2>$null)
        Write-Host "    Active Backend Endpoints:  $backendEp"
        Write-Host "    Active Frontend Endpoints: $frontendEp"
        if ([string]::IsNullOrWhiteSpace($backendEp) -or [string]::IsNullOrWhiteSpace($frontendEp)) {
            Write-Error "Error: Missing ready endpoints for core application services."
            exit 1
        }
    }
} else {
    Write-Host "==> [Verification] Health check skipped as requested (-SkipHealthCheck)." -ForegroundColor DarkYellow
}

# ------------------------------------------------------------------------------
# 7. Summary & Success Output
# ------------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Green
Write-Host "[SUCCESS] DeployX successfully deployed and verified!" -ForegroundColor Green
Write-Host "Namespace:        $Namespace"
Write-Host "Active Color:     $Color"
Write-Host "Deployments:      $($Deployments -join ', ')"
Write-Host "Frontend Service: NodePort 30080"
if ($IncludeMonitoring) {
    Write-Host "Prometheus:       ClusterIP Port 9090 (service: prometheus)"
    Write-Host "Grafana:          ClusterIP Port 3000 (service: grafana)"
}
Write-Host "Log File:         $LogFile"
Write-Host "============================================================" -ForegroundColor Green
Write-Log "INFO" "Deployment pipeline completed successfully for namespace '$Namespace'"
exit 0
