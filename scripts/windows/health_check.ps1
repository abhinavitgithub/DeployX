<#
.SYNOPSIS
    DeployX — Health Verification & Synthetic Diagnostics Controller (PowerShell)
    Inspects Kubernetes pods, services, endpoints, and executes synthetic HTTP probes.

.DESCRIPTION
    Performs comprehensive cluster status checks and synthetic probes against
    backend (/health/live, /health/ready, /api/v1/status, /metrics),
    frontend serving, and optional Prometheus and Grafana instances.

.PARAMETER IncludeMonitoring
    Enforces Prometheus & Grafana health checks as required.

.PARAMETER VerboseOutput
    Prints detailed component specs and endpoints.

.PARAMETER Json
    Outputs health summary in machine-readable JSON.

.PARAMETER Timeout
    Synthetic probe timeout in seconds. Default: 10.

.PARAMETER Namespace
    Target Kubernetes namespace. Default: deployx.

.EXAMPLE
    .\health_check.ps1
    .\health_check.ps1 -IncludeMonitoring
    .\health_check.ps1 -Json
#>

[CmdletBinding()]
param (
    [switch]$IncludeMonitoring,
    [switch]$VerboseOutput,
    [switch]$Json,
    [int]$Timeout = 10,
    [string]$Namespace = "deployx"
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ($env:DEPLOYX_NAMESPACE) { $Namespace = $env:DEPLOYX_NAMESPACE }
if ($env:DEPLOYX_INCLUDE_MONITORING -eq "true") { $IncludeMonitoring = $true }
$LogFile = if ($env:DEPLOYX_LOG_FILE) { $env:DEPLOYX_LOG_FILE } else { Join-Path $RootDir "data\deployx_operations.log" }

function Write-Log {
    param (
        [string]$Level,
        [string]$Message
    )
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    try {
        $LogDir = Split-Path -Parent $LogFile
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        "[$Timestamp] [$Level] [health_check.ps1] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
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

$OverallHealth = "HEALTHY"
$Failures = [System.Collections.Generic.List[string]]::new()

$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlCmd) {
    Write-Error "Error: 'kubectl' command not found in PATH."
    exit 1
}

$clusterInfo = kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    $OverallHealth = "UNHEALTHY"
    $Failures.Add("Kubernetes cluster is not reachable")
}

$nsObj = Get-KubeResourceJson "kubectl get namespace $Namespace -o json"
if ($null -eq $nsObj) {
    $OverallHealth = "UNHEALTHY"
    $Failures.Add("Namespace '$Namespace' does not exist")
}

# Active routing color
$activeColor = "unknown"
$svcObj = Get-KubeResourceJson "kubectl get service backend -n $Namespace -o json"
if ($null -ne $svcObj -and $null -ne $svcObj.spec.selector) {
    $activeColor = $svcObj.spec.selector.'deployment-color'
}
if ([string]::IsNullOrWhiteSpace($activeColor)) { $activeColor = "unknown" }

function Test-DeploymentHealth {
    param (
        [string]$DepName,
        [bool]$IsRequired
    )
    $depObj = Get-KubeResourceJson "kubectl get deployment $DepName -n $Namespace -o json"
    $ready = if ($null -ne $depObj -and $null -ne $depObj.status) { $depObj.status.readyReplicas } else { $null }

    if ($null -eq $ready -or [int]$ready -lt 1) {
        if ($IsRequired) {
            $script:OverallHealth = "UNHEALTHY"
            $script:Failures.Add("Deployment '$DepName' is missing or has zero ready replicas")
        }
        return $false
    }
    return $true
}

function Test-ServiceEndpoints {
    param (
        [string]$SvcName,
        [bool]$IsRequired
    )
    $epObj = Get-KubeResourceJson "kubectl get endpoints $SvcName -n $Namespace -o json"
    $hasEndpoints = $false
    if ($null -ne $epObj -and $null -ne $epObj.subsets) {
        foreach ($subset in $epObj.subsets) {
            if ($null -ne $subset.addresses -and $subset.addresses.Count -gt 0) {
                $hasEndpoints = $true
                break
            }
        }
    }

    if (-not $hasEndpoints) {
        if ($IsRequired) {
            $script:OverallHealth = "UNHEALTHY"
            $script:Failures.Add("Service '$SvcName' has zero ready endpoints")
        }
        return $false
    }
    return $true
}

# Check deployments
$depBackend = if (Test-DeploymentHealth "deployx-backend" $true) { "PASS" } else { "FAIL" }
$depGreen = if (Test-DeploymentHealth "deployx-backend-green" $true) { "PASS" } else { "FAIL" }
$depFrontend = if (Test-DeploymentHealth "deployx-frontend" $true) { "PASS" } else { "FAIL" }

$depProm = "NOT_DEPLOYED"
$depGraf = "NOT_DEPLOYED"
if ($IncludeMonitoring) {
    $depProm = if (Test-DeploymentHealth "deployx-prometheus" $true) { "PASS" } else { "FAIL" }
    $depGraf = if (Test-DeploymentHealth "deployx-grafana" $true) { "PASS" } else { "FAIL" }
} else {
    if (Test-DeploymentHealth "deployx-prometheus" $false) { $depProm = "PASS" }
    if (Test-DeploymentHealth "deployx-grafana" $false) { $depGraf = "PASS" }
}

# Check services
$svcBackend = if (Test-ServiceEndpoints "backend" $true) { "PASS" } else { "FAIL" }
$svcFrontend = if (Test-ServiceEndpoints "deployx-frontend" $true) { "PASS" } else { "FAIL" }
$svcProm = "PASS"
$svcGraf = "PASS"
if ($IncludeMonitoring) {
    $svcProm = if (Test-ServiceEndpoints "prometheus" $true) { "PASS" } else { "FAIL" }
    $svcGraf = if (Test-ServiceEndpoints "grafana" $true) { "PASS" } else { "FAIL" }
}

# Synthetic probes via frontend pod
$probeLiveness = "PASS"
$probeReadiness = "PASS"
$probeStatus = "PASS"
$probeMetrics = "PASS"
$probeFrontend = "PASS"
$probeProm = "PASS"
$probeGraf = "PASS"

$frontendPod = ""
$podsObj = Get-KubeResourceJson "kubectl get pods -n $Namespace -l app=deployx-frontend -o json"
if ($null -ne $podsObj -and $null -ne $podsObj.items -and $podsObj.items.Count -gt 0) {
    $frontendPod = $podsObj.items[0].metadata.name
}

if (-not [string]::IsNullOrWhiteSpace($frontendPod)) {
    # 1. Liveness
    $liveRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://backend:8000/health/live 2>&1
    $liveRes = ($liveRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
    if ($liveRes -notmatch '"status":\s*"alive"') {
        $probeLiveness = "FAIL"
        $OverallHealth = "UNHEALTHY"
        $Failures.Add("Synthetic probe failed: http://backend:8000/health/live")
    }

    # 2. Readiness
    $readyRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://backend:8000/health/ready 2>&1
    $readyRes = ($readyRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
    if ($readyRes -notmatch '"status":\s*"ready"') {
        $probeReadiness = "FAIL"
        $OverallHealth = "UNHEALTHY"
        $Failures.Add("Synthetic probe failed: http://backend:8000/health/ready")
    }

    # 3. Status
    $statusRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://backend:8000/api/v1/status 2>&1
    $statusRes = ($statusRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
    if ($statusRes -notmatch '"process_status":\s*"running"') {
        $probeStatus = "FAIL"
        $OverallHealth = "UNHEALTHY"
        $Failures.Add("Synthetic probe failed: http://backend:8000/api/v1/status")
    }

    # 4. Metrics
    $metricsRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://backend:8000/metrics 2>&1
    $metricsRes = ($metricsRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
    if ($metricsRes -notmatch 'deployx_') {
        $probeMetrics = "FAIL"
        $OverallHealth = "UNHEALTHY"
        $Failures.Add("Synthetic probe failed: http://backend:8000/metrics")
    }

    # 5. Frontend HTML
    $feRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://127.0.0.1:80 2>&1
    $feRes = ($feRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
    if ($feRes -notmatch 'DeployX') {
        $probeFrontend = "FAIL"
        $OverallHealth = "UNHEALTHY"
        $Failures.Add("Synthetic probe failed: frontend HTML serving on port 80")
    }

    # 6. Monitoring probes
    if ($IncludeMonitoring) {
        $promRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://prometheus:9090/-/healthy 2>&1
        $promRes = ($promRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
        if ($promRes -notmatch 'Prometheus Server is Healthy') {
            $probeProm = "FAIL"
            $OverallHealth = "UNHEALTHY"
            $Failures.Add("Synthetic probe failed: http://prometheus:9090/-/healthy")
        }

        $grafRaw = kubectl exec -n $Namespace $frontendPod -- wget -qO- -T $Timeout http://grafana:3000/api/health 2>&1
        $grafRes = ($grafRaw | Where-Object { $_ -notmatch '^\s*Defaulted container' }) -join "`n"
        if ($grafRes -notmatch '"database":\s*"ok"') {
            $probeGraf = "FAIL"
            $OverallHealth = "UNHEALTHY"
            $Failures.Add("Synthetic probe failed: http://grafana:3000/api/health")
        }
    }
} else {
    $OverallHealth = "UNHEALTHY"
    $Failures.Add("No running frontend pod found to execute synthetic probes")
    $probeLiveness = "FAIL"
    $probeReadiness = "FAIL"
    $probeStatus = "FAIL"
    $probeMetrics = "FAIL"
    $probeFrontend = "FAIL"
}

if ($Json) {
    $report = [PSCustomObject]@{
        status = $OverallHealth
        namespace = $Namespace
        active_routing_color = $activeColor
        deployments = [PSCustomObject]@{
            "deployx-backend" = $depBackend
            "deployx-backend-green" = $depGreen
            "deployx-frontend" = $depFrontend
            "deployx-prometheus" = $depProm
            "deployx-grafana" = $depGraf
        }
        services = [PSCustomObject]@{
            "backend" = $svcBackend
            "deployx-frontend" = $svcFrontend
            "prometheus" = $svcProm
            "grafana" = $svcGraf
        }
        probes = [PSCustomObject]@{
            "backend_liveness" = $probeLiveness
            "backend_readiness" = $probeReadiness
            "backend_status" = $probeStatus
            "backend_metrics" = $probeMetrics
            "frontend_html" = $probeFrontend
            "prometheus_healthy" = $probeProm
            "grafana_healthy" = $probeGraf
        }
        failure_count = $Failures.Count
    }
    $report | ConvertTo-Json -Depth 4
} else {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "==> [DeployX] System Health & Synthetic Verification" -ForegroundColor Cyan
    Write-Host "    Namespace:       $Namespace"
    Write-Host "    Active Routing:  $activeColor"
    Write-Host "    Overall Status:  $OverallHealth"
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Deployments:"
    Write-Host ("  {0,-24} [{1}]" -f "deployx-backend (Blue)", $depBackend)
    Write-Host ("  {0,-24} [{1}]" -f "deployx-backend-green", $depGreen)
    Write-Host ("  {0,-24} [{1}]" -f "deployx-frontend", $depFrontend)
    if ($IncludeMonitoring -or $depProm -ne "NOT_DEPLOYED") {
        Write-Host ("  {0,-24} [{1}]" -f "deployx-prometheus", $depProm)
        Write-Host ("  {0,-24} [{1}]" -f "deployx-grafana", $depGraf)
    }

    Write-Host "`nRouting & Service Endpoints:"
    Write-Host ("  {0,-24} [{1}]" -f "backend (active: $activeColor)", $svcBackend)
    Write-Host ("  {0,-24} [{1}]" -f "deployx-frontend (30080)", $svcFrontend)
    if ($IncludeMonitoring) {
        Write-Host ("  {0,-24} [{1}]" -f "prometheus (9090)", $svcProm)
        Write-Host ("  {0,-24} [{1}]" -f "grafana (3000)", $svcGraf)
    }

    Write-Host "`nSynthetic Probes:"
    Write-Host ("  {0,-24} [{1}]" -f "/health/live", $probeLiveness)
    Write-Host ("  {0,-24} [{1}]" -f "/health/ready", $probeReadiness)
    Write-Host ("  {0,-24} [{1}]" -f "/api/v1/status", $probeStatus)
    Write-Host ("  {0,-24} [{1}]" -f "/metrics", $probeMetrics)
    Write-Host ("  {0,-24} [{1}]" -f "Frontend HTTP (port 80)", $probeFrontend)
    if ($IncludeMonitoring) {
        Write-Host ("  {0,-24} [{1}]" -f "Prometheus (/-/healthy)", $probeProm)
        Write-Host ("  {0,-24} [{1}]" -f "Grafana (/api/health)", $probeGraf)
    }

    if ($Failures.Count -gt 0) {
        Write-Host "`nIdentified Failures / Degraded States:" -ForegroundColor Red
        foreach ($f in $Failures) {
            Write-Host "  - [FAIL] $f" -ForegroundColor Red
        }
    }
    Write-Host "============================================================" -ForegroundColor Cyan
}

if ($OverallHealth -ne "HEALTHY") {
    Write-Log "WARN" "Health check identified $($Failures.Count) issues: $($Failures -join '; ')"
    exit 1
}

Write-Log "INFO" "Health check succeeded: all components healthy, active color is '$activeColor'"
exit 0
