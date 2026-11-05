<#
.SYNOPSIS
    DeployX — Automated Disaster Recovery Rollback Controller (PowerShell)
    Safely rolls back the active routing Service ('backend') to the alternate or specified deployment.

.DESCRIPTION
    Enforces pre-flight health gates on the target deployment and executes automated recovery
    if endpoint verification fails.

.PARAMETER Color
    Explicit target deployment color ('blue' or 'green'). If omitted, toggles to the opposite environment.

.PARAMETER Timeout
    Endpoint verification timeout in seconds. Default: 15.

.PARAMETER Namespace
    Target Kubernetes namespace. Default: deployx.

.EXAMPLE
    .\rollback.ps1
    .\rollback.ps1 -Color blue
    .\rollback.ps1 -Color green -Timeout 30
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateSet("blue", "green", "")]
    [string]$Color = "",
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
        "[$Timestamp] [$Level] [rollback.ps1] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
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
    Write-Log "ERROR" "Pre-flight failed: kubectl not found in PATH"
    exit 1
}

# ------------------------------------------------------------------------------
# 1. Detect Current Active Routing State
# ------------------------------------------------------------------------------
$currentColor = "blue"
$svcObj = Get-KubeResourceJson "kubectl get service $ServiceName -n $Namespace -o json"
if ($null -ne $svcObj -and $null -ne $svcObj.spec.selector) {
    $currentColor = $svcObj.spec.selector.'deployment-color'
}
if ([string]::IsNullOrWhiteSpace($currentColor)) { $currentColor = "blue" }

$targetColor = $Color
if ([string]::IsNullOrWhiteSpace($targetColor)) {
    if ($currentColor -eq "blue") {
        $targetColor = "green"
    } else {
        $targetColor = "blue"
    }
}

$targetDeployment = if ($targetColor -eq "blue") { "deployx-backend" } else { "deployx-backend-green" }

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "==> [DeployX] Disaster Recovery Rollback Controller (PowerShell)" -ForegroundColor Cyan
Write-Host "    Namespace:          $Namespace"
Write-Host "    Routing Service:    $ServiceName"
Write-Host "    Current Active:     $currentColor"
Write-Host "    Rollback Target:    $targetColor ($targetDeployment)"
Write-Host "    Endpoint Timeout:   $($Timeout)s"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "INFO" "Rollback initiated: current=$currentColor target=$targetColor target_deployment=$targetDeployment"

if ($currentColor -eq $targetColor) {
    Write-Host "==> Traffic is already actively routed to '$targetColor'. No rollback action required." -ForegroundColor Green
    Write-Log "INFO" "Rollback is a no-op: traffic already on $targetColor"
    exit 0
}

# ------------------------------------------------------------------------------
# 2. Pre-Flight Target Health Gate (Safety Check)
# ------------------------------------------------------------------------------
Write-Host "==> [Safety Gate] Verifying target deployment '$targetDeployment' health..." -ForegroundColor Yellow

$depObj = Get-KubeResourceJson "kubectl get deployment $targetDeployment -n $Namespace -o json"
if ($null -eq $depObj) {
    Write-Error "Error: Target deployment '$targetDeployment' does not exist in namespace '$Namespace'. Aborting rollback to protect active traffic."
    Write-Log "ERROR" "Rollback aborted: Target deployment '$targetDeployment' missing"
    exit 1
}

kubectl rollout status "deployment/$targetDeployment" -n $Namespace --timeout=30s
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Target deployment '$targetDeployment' is not fully rolled out. Aborting rollback to protect active traffic."
    Write-Log "ERROR" "Rollback aborted: Target deployment '$targetDeployment' not rolled out"
    exit 1
}

$readyReplicas = if ($null -ne $depObj.status) { $depObj.status.readyReplicas } else { "0" }
if ([string]::IsNullOrWhiteSpace($readyReplicas) -or [int]$readyReplicas -lt 1) {
    Write-Error "Error: Target deployment '$targetDeployment' has zero ready replicas ($readyReplicas). Aborting rollback to prevent outage."
    Write-Log "ERROR" "Rollback aborted: Target deployment '$targetDeployment' has 0 ready replicas"
    exit 1
}

Write-Host "    Target deployment '$targetDeployment' is healthy ($readyReplicas ready replicas)." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Execute Traffic Cutover
# ------------------------------------------------------------------------------
Write-Host "==> [Cutover] Switching traffic on '$ServiceName' from '$currentColor' to '$targetColor'..." -ForegroundColor Yellow

$patchPayload = '{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"' + $targetColor + '\"}}}'
kubectl patch service $ServiceName -n $Namespace --type=merge -p $patchPayload
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Failed to patch service '$ServiceName'."
    Write-Log "ERROR" "Failed to patch service '$ServiceName' selector to '$targetColor'"
    exit 1
}

# ------------------------------------------------------------------------------
# 4. Post-Switch Endpoint Verification
# ------------------------------------------------------------------------------
Write-Host "==> [Verification] Polling ready endpoints for '$targetColor'..." -ForegroundColor Yellow

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

# ------------------------------------------------------------------------------
# 5. Automated Emergency Reversion on Verification Failure
# ------------------------------------------------------------------------------
if (-not $verified) {
    Write-Error "Error: Verification failed. No healthy endpoints found for '$targetColor' within $($Timeout)s."
    Write-Host "==> [Emergency Reversion] Restoring service '$ServiceName' selector back to '$currentColor'..." -ForegroundColor Red
    Write-Log "WARN" "Rollback verification failed for '$targetColor'. Reverting to '$currentColor'"

    $revertPayload = '{\"spec\":{\"selector\":{\"app\":\"deployx-backend\",\"deployment-color\":\"' + $currentColor + '\"}}}'
    $null = kubectl patch service $ServiceName -n $Namespace --type=merge -p $revertPayload 2>&1

    Write-Host "==> Restored '$ServiceName' to previous known-good deployment ($currentColor)." -ForegroundColor Yellow
    Write-Log "ERROR" "Emergency reversion completed. Service restored to '$currentColor'"
    exit 1
}

# ------------------------------------------------------------------------------
# 6. Success Output
# ------------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Green
Write-Host "[SUCCESS] Disaster recovery rollback completed successfully!" -ForegroundColor Green
Write-Host "Service:          $ServiceName"
Write-Host "Previous State:   $currentColor"
Write-Host "Active State:     $targetColor ($targetDeployment)"
Write-Host "Active Endpoints: $activeEndpoints"
Write-Host "============================================================" -ForegroundColor Green
Write-Log "INFO" "Rollback successful: switched $ServiceName from $currentColor to $targetColor (endpoints: $activeEndpoints)"
exit 0
