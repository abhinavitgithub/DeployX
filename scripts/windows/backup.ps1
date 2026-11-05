<#
.SYNOPSIS
    DeployX — Cluster State & Configuration Backup Controller (PowerShell)
    Exports and archives Kubernetes manifests, active routing state, monitoring configurations,
    and runtime metadata with configurable backup retention.

.DESCRIPTION
    Creates timestamped backups of all DeployX Kubernetes manifests, pod inventories,
    and metadata in .zip format. Enforces retention limits by pruning older backups.

.PARAMETER Dir
    Output directory for backup archives. Default: backups.

.PARAMETER Retention
    Maximum number of backups to keep. Default: 5.

.PARAMETER Namespace
    Target Kubernetes namespace. Default: deployx.

.EXAMPLE
    .\backup.ps1
    .\backup.ps1 -Retention 10
    .\backup.ps1 -Dir C:\backups -Namespace deployx
#>

[CmdletBinding()]
param (
    [string]$Dir = "",
    [int]$Retention = 5,
    [string]$Namespace = "deployx",
    [string]$S3Bucket = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)

if ($env:DEPLOYX_NAMESPACE) { $Namespace = $env:DEPLOYX_NAMESPACE }
if ($env:DEPLOYX_BACKUP_RETENTION) { $Retention = [int]$env:DEPLOYX_BACKUP_RETENTION }
$BackupRoot = if (-not [string]::IsNullOrWhiteSpace($Dir)) { $Dir } elseif ($env:DEPLOYX_BACKUP_DIR) { $env:DEPLOYX_BACKUP_DIR } else { Join-Path $RootDir "backups" }
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
        "[$Timestamp] [$Level] [backup.ps1] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch { }
}

$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlCmd) {
    Write-Error "Error: 'kubectl' command not found in PATH."
    Write-Log "ERROR" "Backup failed: kubectl not found in PATH"
    exit 1
}

$Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$BackupName = "deployx_backup_$Timestamp"
$BackupDir = Join-Path $BackupRoot $BackupName

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "==> [DeployX] Executing Cluster State Backup (PowerShell)" -ForegroundColor Cyan
Write-Host "    Namespace:       $Namespace"
Write-Host "    Backup Target:   $BackupDir"
Write-Host "    Retention Limit: $Retention archives"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "INFO" "Starting backup: name=$BackupName namespace=$Namespace"

$K8sBackupDir = Join-Path $BackupDir "kubernetes"
$MetaBackupDir = Join-Path $BackupDir "metadata"
New-Item -ItemType Directory -Path $K8sBackupDir -Force | Out-Null
New-Item -ItemType Directory -Path $MetaBackupDir -Force | Out-Null

# Active color and Git metadata
$activeColor = (kubectl get service backend -n $Namespace -o jsonpath='{.spec.selector.deployment-color}' 2>$null)
if ([string]::IsNullOrWhiteSpace($activeColor)) { $activeColor = "unknown" }

$gitCommit = "not_in_git"
$gitBranch = "unknown"
try {
    $gitCommit = (git -C $RootDir rev-parse HEAD 2>$null)
    $gitBranch = (git -C $RootDir rev-parse --abbrev-ref HEAD 2>$null)
} catch { }

$manifestJson = [PSCustomObject]@{
    backup_name = $BackupName
    created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    namespace = $Namespace
    active_routing_color = $activeColor
    git_commit = $gitCommit
    git_branch = $gitBranch
}
$manifestJson | ConvertTo-Json | Out-File -FilePath (Join-Path $MetaBackupDir "manifest.json") -Encoding utf8

# Export Kubernetes resources
Write-Host "==> [Export] Capturing Kubernetes cluster resources..." -ForegroundColor Yellow

kubectl get namespace $Namespace -o yaml 2>$null | Out-File -FilePath (Join-Path $K8sBackupDir "namespace.yaml") -Encoding utf8
kubectl get deployments -n $Namespace -o yaml 2>$null | Out-File -FilePath (Join-Path $K8sBackupDir "deployments.yaml") -Encoding utf8
kubectl get services -n $Namespace -o yaml 2>$null | Out-File -FilePath (Join-Path $K8sBackupDir "services.yaml") -Encoding utf8
kubectl get configmaps -n $Namespace -o yaml 2>$null | Out-File -FilePath (Join-Path $K8sBackupDir "configmaps.yaml") -Encoding utf8
kubectl get secrets -n $Namespace -o yaml 2>$null | Out-File -FilePath (Join-Path $K8sBackupDir "secrets.yaml") -Encoding utf8
kubectl get pods -n $Namespace -o wide 2>$null | Out-File -FilePath (Join-Path $MetaBackupDir "pods.txt") -Encoding utf8

# Copy local manifests
$localK8s = Join-Path $RootDir "infrastructure\kubernetes"
if (Test-Path $localK8s) {
    $localTarget = Join-Path $BackupDir "local_manifests"
    Copy-Item -Path "$localK8s\*" -Destination $localTarget -Recurse -Force 2>$null
}

# Compress into zip
Write-Host "==> [Archive] Compressing backup into .zip..." -ForegroundColor Yellow
$ZipPath = "$BackupRoot\$BackupName.zip"
try {
    Compress-Archive -Path "$BackupDir\*" -DestinationPath $ZipPath -Force
    Remove-Item -Path $BackupDir -Recurse -Force
    $FinalBackupFile = $ZipPath
} catch {
    $FinalBackupFile = $BackupDir
}

Write-Host "    Backup created: $FinalBackupFile" -ForegroundColor Green

# Optional S3 Replication
if (-not [string]::IsNullOrWhiteSpace($S3Bucket) -or -not [string]::IsNullOrWhiteSpace($env:DEPLOYX_S3_BACKUP_BUCKET)) {
    $targetBucket = if (-not [string]::IsNullOrWhiteSpace($S3Bucket)) { $S3Bucket } else { $env:DEPLOYX_S3_BACKUP_BUCKET }
    Write-Host "==> [AWS S3] Replicating backup to S3 bucket '$targetBucket'..." -ForegroundColor Yellow
    if (Get-Command aws -ErrorAction SilentlyContinue) {
        $archiveName = Split-Path -Leaf $FinalBackupFile
        aws s3 cp "$FinalBackupFile" "s3://$targetBucket/backups/$archiveName" --sse AES256
        Write-Host "    Replicated to: s3://$targetBucket/backups/$archiveName" -ForegroundColor Green
        Write-Log "INFO" "Replicated backup to s3://$targetBucket/backups/$archiveName"
    } else {
        Write-Warning "AWS CLI ('aws') not found in PATH; skipping S3 replication."
        Write-Log "WARN" "AWS CLI not found; skipped S3 replication to $targetBucket"
    }
}

# Retention management
Write-Host "==> [Retention] Enforcing retention limit ($Retention)..." -ForegroundColor Yellow
if (Test-Path $BackupRoot) {
    $existing = Get-ChildItem -Path $BackupRoot | Where-Object { $_.Name -like "deployx_backup_*" } | Sort-Object LastWriteTime
    if ($existing.Count -gt $Retention) {
        $excess = $existing.Count - $Retention
        Write-Host "    Pruning $excess oldest backup(s)..." -ForegroundColor DarkYellow
        for ($i = 0; $i -lt $excess; $i++) {
            $oldItem = $existing[$i]
            Write-Host "    Pruned: $($oldItem.Name)"
            Remove-Item -Path $oldItem.FullName -Recurse -Force
            Write-Log "INFO" "Pruned old backup: $($oldItem.Name)"
        }
    } else {
        Write-Host "    Total backups ($($existing.Count)) within retention limit ($Retention)."
    }
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host "[SUCCESS] Backup completed successfully!" -ForegroundColor Green
Write-Host "Archive:          $FinalBackupFile"
Write-Host "Active Color:     $activeColor"
Write-Host "Git Commit:       $gitCommit"
Write-Host "Retention Limit:  $Retention"
Write-Host "============================================================" -ForegroundColor Green
Write-Log "INFO" "Backup created successfully: file=$FinalBackupFile active_color=$activeColor"
exit 0
