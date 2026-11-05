<#
.SYNOPSIS
    DeployX — Cluster Cleanup & Teardown Controller (PowerShell)
    Provides safe, tiered teardown of DeployX Kubernetes resources.

.DESCRIPTION
    Safely tears down Kubernetes resources across tiers (all, monitoring-only, or green-only).
    Requires explicit confirmation unless -Force is supplied.

.PARAMETER All
    Removes all DeployX resources including namespace (default).

.PARAMETER MonitoringOnly
    Removes only Phase 6 Prometheus & Grafana monitoring stack.

.PARAMETER GreenOnly
    Removes only inactive Green deployment.

.PARAMETER DryRun
    Previews targeted resources without executing deletion.

.PARAMETER Force
    Bypasses interactive confirmation prompt.

.PARAMETER Namespace
    Target Kubernetes namespace. Default: deployx.

.EXAMPLE
    .\cleanup.ps1 -DryRun
    .\cleanup.ps1 -All -Force
    .\cleanup.ps1 -MonitoringOnly
    .\cleanup.ps1 -GreenOnly -Force
#>

[CmdletBinding()]
param (
    [switch]$All,
    [switch]$MonitoringOnly,
    [switch]$GreenOnly,
    [switch]$DryRun,
    [switch]$Force,
    [string]$Namespace = "deployx"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ($env:DEPLOYX_NAMESPACE) { $Namespace = $env:DEPLOYX_NAMESPACE }
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
        "[$Timestamp] [$Level] [cleanup.ps1] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch { }
}

$Mode = "all"
if ($MonitoringOnly) { $Mode = "monitoring-only" }
if ($GreenOnly) { $Mode = "green-only" }

$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlCmd) {
    Write-Error "Error: 'kubectl' command not found in PATH."
    exit 1
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "==> [DeployX] Cluster Teardown Controller (PowerShell)" -ForegroundColor Cyan
Write-Host "    Namespace:  $Namespace"
Write-Host "    Mode:       $Mode"
Write-Host "    Dry Run:    $DryRun"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "INFO" "Cleanup initiated: mode=$Mode namespace=$Namespace dry_run=$DryRun"

# Preview
Write-Host "==> [Inventory] Targeted resources for removal ($Mode):" -ForegroundColor Yellow
switch ($Mode) {
    "all" {
        Write-Host "  - Complete Namespace: $Namespace"
        Write-Host "  - Deployments:        deployx-backend, deployx-backend-green, deployx-frontend, deployx-prometheus, deployx-grafana"
        Write-Host "  - Services:           deployx-backend, backend, deployx-frontend, prometheus, grafana"
        Write-Host "  - ConfigMaps/Secrets: all associated with deployx"
    }
    "monitoring-only" {
        Write-Host "  - Deployments:        deployx-prometheus, deployx-grafana"
        Write-Host "  - Services:           prometheus, grafana"
        Write-Host "  - ConfigMaps:         deployx-prometheus-config, deployx-grafana-datasources, deployx-grafana-dashboards, deployx-grafana-dashboard-provider"
        Write-Host "  - Secrets:            deployx-grafana-secret"
    }
    "green-only" {
        Write-Host "  - Deployment:         deployx-backend-green"
    }
}

if ($DryRun) {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "[SUCCESS] Dry-run completed. No resources were deleted." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Log "INFO" "Cleanup dry-run completed successfully"
    exit 0
}

# Safety confirmation
if (-not $Force) {
    $confirm = Read-Host "WARNING: Are you sure you want to proceed with teardown ($Mode)? [y/N]"
    if ($confirm -ne "y" -and $confirm -ne "Y" -and $confirm -ne "yes") {
        Write-Host "Cleanup cancelled by user."
        Write-Log "INFO" "Cleanup cancelled by user"
        exit 0
    }
}

# Execution
Write-Host "==> [Teardown] Executing resource deletion..." -ForegroundColor Yellow
switch ($Mode) {
    "all" {
        $null = kubectl get namespace $Namespace 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Deleting namespace '$Namespace' and all enclosed resources..."
            $null = kubectl delete namespace $Namespace --wait=true 2>&1
            Write-Host "    Namespace '$Namespace' deleted." -ForegroundColor Green
        } else {
            Write-Host "    Namespace '$Namespace' does not exist."
        }
    }
    "monitoring-only" {
        Write-Host "    Deleting monitoring deployments and services..."
        $null = kubectl delete deployment deployx-prometheus deployx-grafana -n $Namespace --ignore-not-found=true 2>&1
        $null = kubectl delete service prometheus deployx-prometheus grafana deployx-grafana -n $Namespace --ignore-not-found=true 2>&1
        $null = kubectl delete configmap deployx-prometheus-config deployx-grafana-datasources deployx-grafana-dashboards deployx-grafana-dashboard-provider -n $Namespace --ignore-not-found=true 2>&1
        $null = kubectl delete secret deployx-grafana-secret -n $Namespace --ignore-not-found=true 2>&1
        Write-Host "    Monitoring stack removed." -ForegroundColor Green
    }
    "green-only" {
        $activeColor = (kubectl get service backend -n $Namespace -o jsonpath='{.spec.selector.deployment-color}' 2>$null)
        if ($activeColor -eq "green") {
            Write-Error "Error: Cannot delete Green deployment because it is currently actively receiving traffic! Roll back traffic to Blue first."
            Write-Log "ERROR" "Cleanup green-only aborted: Green deployment actively receiving traffic"
            exit 1
        }
        Write-Host "    Deleting inactive deployment 'deployx-backend-green'..."
        $null = kubectl delete deployment deployx-backend-green -n $Namespace --ignore-not-found=true 2>&1
        Write-Host "    Deployment 'deployx-backend-green' removed." -ForegroundColor Green
    }
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host "[SUCCESS] Cleanup completed successfully for mode: $Mode" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Log "INFO" "Cleanup completed successfully: mode=$Mode namespace=$Namespace"
exit 0
