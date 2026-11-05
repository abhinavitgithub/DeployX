<#
.SYNOPSIS
    DeployX — Blue-Green Traffic Switching Controller (PowerShell)
    Switches the active Kubernetes routing service ('backend') between Blue and Green deployments.

.DESCRIPTION
    Validates target deployment readiness before cutover and automatically rolls back on endpoint failure.

.PARAMETER Color
    Target deployment color ('blue' or 'green').

.PARAMETER Timeout
    Endpoint verification timeout in seconds. Default: 15.

.PARAMETER Namespace
    Target Kubernetes namespace. Default: deployx.

.EXAMPLE
    .\switch_traffic.ps1 blue
    .\switch_traffic.ps1 green -Timeout 20
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("blue", "green")]
    [string]$Color,
    [int]$Timeout = 15,
    [string]$Namespace = "deployx"
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ($env:DEPLOYX_NAMESPACE) { $Namespace = $env:DEPLOYX_NAMESPACE }
if ($env:DEPLOYX_ENDPOINT_TIMEOUT) { $Timeout = [int]$env:DEPLOYX_ENDPOINT_TIMEOUT }
$ServiceName = if ($env:DEPLOYX_BACKEND_SERVICE) { $env:DEPLOYX_BACKEND_SERVICE } else { "backend" }
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
        "[$Timestamp] [$Level] [switch_traffic.ps1] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
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

$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlCmd) {
    Write-Error "Error: 'kubectl' command not found in PATH."
    exit 1
}

$targetDeployment = if ($Color -eq "blue") { "deployx-backend" } else { "deployx-backend-green" }

Write-Host "==> [Pre-flight] Verifying target deployment '$targetDeployment' in namespace '$Namespace'..." -ForegroundColor Yellow

$depObj = Get-KubeResourceJson "kubectl get deployment $targetDeployment -n $Namespace -o json"
if ($null -eq $depObj) {
    Write-Error "Error: Deployment '$targetDeployment' does not exist in namespace '$Namespace'."
    exit 1
}

kubectl rollout status "deployment/$targetDeployment" -n $Namespace --timeout=30s
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Target deployment '$targetDeployment' is not fully rolled out. Aborting traffic switch."
    exit 1
}

$readyReplicas = if ($null -ne $depObj.status) { $depObj.status.readyReplicas } else { "0" }
if ([string]::IsNullOrWhiteSpace($readyReplicas) -or [int]$readyReplicas -lt 1) {
    Write-Error "Error: Deployment '$targetDeployment' has zero ready replicas ($readyReplicas). Aborting traffic switch."
    exit 1
}

# Capture current color
$prevColor = "blue"
$svcObj = Get-KubeResourceJson "kubectl get service $ServiceName -n $Namespace -o json"
if ($null -ne $svcObj -and $null -ne $svcObj.spec.selector) {
    $prevColor = $svcObj.spec.selector.'deployment-color'
}
if ([string]::IsNullOrWhiteSpace($prevColor)) { $prevColor = "blue" }

if ($prevColor -eq $Color) {
    Write-Host "==> Traffic is already routed to '$Color'. No switch required." -ForegroundColor Green
    exit 0
}

Write-Host "==> [Cutover] Switching traffic on service '$ServiceName' from '$prevColor' to '$Color'..." -ForegroundColor Yellow
$patchPayload = '{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"' + $Color + '\"}}}'
kubectl patch service $ServiceName -n $Namespace --type=merge -p $patchPayload
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Failed to patch service '$ServiceName'."
    exit 1
}

Write-Host "==> [Verification] Polling active endpoints for '$ServiceName' ($Color)..." -ForegroundColor Yellow
$verified = $false
$activeEndpoints = ""

for ($i = 0; $i -lt $Timeout; $i++) {
    $epObj = Get-KubeResourceJson "kubectl get endpoints $ServiceName -n $Namespace -o json"
    if ($null -ne $epObj -and $null -ne $epObj.subsets) {
        $ips = @()
        foreach ($sub in $epObj.subsets) {
            if ($null -ne $sub.addresses) {
                $ips += ($sub.addresses | ForEach-Object { $_.ip })
            }
        }
        if ($ips.Count -gt 0) {
            $activeEndpoints = ($ips -join " ")
            $verified = $true
            break
        }
    }
    Start-Sleep -Seconds 1
}

if (-not $verified) {
    Write-Error "Error: Verification failed. No healthy endpoints found for '$Color' within timeout."
    Write-Host "==> [Rollback] Restoring service '$ServiceName' selector to '$prevColor'..." -ForegroundColor Red
    $rollbackPayload = '{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"' + $prevColor + '\"}}}'
    $null = kubectl patch service $ServiceName -n $Namespace --type=merge -p $rollbackPayload 2>&1
    Write-Host "==> [Rollback] Restored '$ServiceName' selector to '$prevColor'." -ForegroundColor Yellow
    exit 1
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host "[SUCCESS] Traffic successfully switched to $Color." -ForegroundColor Green
Write-Host "Service:          $ServiceName"
Write-Host "Target:           $targetDeployment"
Write-Host "Active Endpoints: $activeEndpoints"
Write-Host "============================================================" -ForegroundColor Green
Write-Log "INFO" "Traffic switched to $Color on $ServiceName (endpoints: $activeEndpoints)"
exit 0
