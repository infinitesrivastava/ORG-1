
$UseProfile      = $true            
$ProfileName     = "default"       
$DaysBack        = 30               
$OutCsv          = Join-Path $env:USERPROFILE "Downloads\S3_report$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$FallbackRegion  = "us-east-1"      


function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        try {
            if (-not (Get-Module -ListAvailable -Name AWS.Tools.Installer)) {
                Install-Module -Name AWS.Tools.Installer -Force -ErrorAction Stop
            }
            Install-Module -Name $Name -Force -ErrorAction Stop
        } catch {
            throw "Failed to install module '$Name': $($_.Exception.Message)"
        }
    }
    Import-Module $Name -ErrorAction Stop | Out-Null
}

Ensure-Module -Name AWS.Tools.Common
Ensure-Module -Name AWS.Tools.S3
Ensure-Module -Name AWS.Tools.CloudWatch
Ensure-Module -Name AWS.Tools.SecurityToken


if ($UseProfile) {
    Initialize-AWSDefaultConfiguration -ProfileName $ProfileName -Region $FallbackRegion
} else {
    Write-Host "Enter temporary STS credentials (ASIA.. / Secret / SessionToken)" -ForegroundColor Cyan
    $ak = Read-Host "AccessKeyId"
    $sk = Read-Host "SecretAccessKey"
    $st = Read-Host "SessionToken"
    if ([string]::IsNullOrWhiteSpace($ak) -or [string]::IsNullOrWhiteSpace($sk) -or [string]::IsNullOrWhiteSpace($st)) {
        throw "All three values (AccessKey, SecretKey, SessionToken) are required."
    }
    Initialize-AWSDefaultConfiguration -Region $FallbackRegion -AccessKey $ak -SecretKey $sk -SessionToken $st
}


(Get-STSCallerIdentity -ErrorAction Stop) | Out-Null



$AllRegions = @(
    'us-east-1','us-east-2','us-west-1','us-west-2',
    'af-south-1',
    'ap-east-1','ap-south-1','ap-south-2','ap-southeast-1','ap-southeast-2','ap-southeast-3',
    'ap-northeast-1','ap-northeast-2','ap-northeast-3',
    'ca-central-1',
    'eu-central-1','eu-central-2','eu-west-1','eu-west-2','eu-west-3','eu-north-1','eu-south-1','eu-south-2',
    'me-south-1','me-central-1',
    'sa-east-1'
)

# Storage types
$StorageTypes = @(
    "StandardStorage",
    "StandardIAStorage",
    "OneZoneIAStorage",
    "ReducedRedundancyStorage",
    "GlacierStorage",
    "DeepArchiveStorage",
    "GlacierStagingStorage",
    "IntelligentTieringFAStorage",
    "IntelligentTieringIAStorage",
    "IntelligentTieringAAStorage",
    "IntelligentTieringDAStorage"
)


$EndUtc   = (Get-Date).ToUniversalTime()
$StartUtc = $EndUtc.AddDays(-1 * $DaysBack)
$Period   = 86400  # 1 day

# Get bucket list
$buckets = Get-S3Bucket -ErrorAction Stop
if (-not $buckets) {
    Write-Warning "No buckets found for this identity."
    return
}

# detect the CloudWatch region where this bucket publishes S3 metrics
function Detect-BucketRegionFromCW {
    param([Parameter(Mandatory)][string]$BucketName)
    foreach ($r in $AllRegions) {
        try {
            Set-DefaultAWSRegion -Region $r
            
            $probe = Get-CWMetricStatistics -Namespace 'AWS/S3' -MetricName 'NumberOfObjects' `
                        -Dimensions @{ Name='BucketName'; Value=$BucketName }, @{ Name='StorageType'; Value='AllStorageTypes' } `
                        -StartTime $StartUtc -EndTime $EndUtc -Period $Period -Statistics Average -ErrorAction Stop
            if ($probe.Datapoints.Count -gt 0) { return $r }

            $probe2 = Get-CWMetricStatistics -Namespace 'AWS/S3' -MetricName 'BucketSizeBytes' `
                        -Dimensions @{ Name='BucketName'; Value=$BucketName }, @{ Name='StorageType'; Value='StandardStorage' } `
                        -StartTime $StartUtc -EndTime $EndUtc -Period $Period -Statistics Average -ErrorAction Stop
            if ($probe2.Datapoints.Count -gt 0) { return $r }
        } catch {
            continue
        }
    }
    return $FallbackRegion
}


$result = New-Object System.Collections.Generic.List[object]

foreach ($b in $buckets) {
    $bucket = $b.BucketName

    # Detect region by probing CloudWatch 
    $bucketRegion = Detect-BucketRegionFromCW -BucketName $bucket
    Set-DefaultAWSRegion -Region $bucketRegion

    #NumberOfObjects
    try {
        $objStats = Get-CWMetricStatistics -Namespace 'AWS/S3' -MetricName 'NumberOfObjects' `
            -Dimensions @{ Name='BucketName'; Value=$bucket }, @{ Name='StorageType'; Value='AllStorageTypes' } `
            -StartTime $StartUtc -EndTime $EndUtc -Period $Period -Statistics Average -ErrorAction Stop
    } catch {
        $objStats = @()
    }
    $objByDay = @{}
    foreach ($dp in $objStats.Datapoints) {
        $objByDay[$dp.Timestamp.Date] = [int64]([Math]::Round($dp.Average))
    }

    # BucketSizeBytes
    $sizeByDay = @{}
    foreach ($st in $StorageTypes) {
        try {
            $sz = Get-CWMetricStatistics -Namespace 'AWS/S3' -MetricName 'BucketSizeBytes' `
                -Dimensions @{ Name='BucketName'; Value=$bucket }, @{ Name='StorageType'; Value=$st } `
                -StartTime $StartUtc -EndTime $EndUtc -Period $Period -Statistics Average -ErrorAction Stop
            foreach ($dp in $sz.Datapoints) {
                $day = $dp.Timestamp.Date
                if (-not $sizeByDay.ContainsKey($day)) { $sizeByDay[$day] = [int64]0 }
                $sizeByDay[$day] += [int64]([Math]::Round($dp.Average))
            }
        } catch { continue }
    }

    for ($d=0; $d -lt $DaysBack; $d++) {
        $day = ($StartUtc.Date).AddDays($d)
        $bytes = $(if ($sizeByDay.ContainsKey($day)) { $sizeByDay[$day] } else { 0 })
        $objs  = $(if ($objByDay.ContainsKey($day))  { $objByDay[$day]  } else { 0 })

        $result.Add([PSCustomObject]@{
            Date        = $day.ToString("yyyy-MM-dd")
            BucketName  = $bucket
            Region      = $bucketRegion
            ObjectCount = $objs
            SizeBytes   = $bytes
            SizeKB      = [Math]::Round(($bytes / 1KB), 2)
            SizeMB      = [Math]::Round(($bytes / 1MB), 2)
            SizeGB      = [Math]::Round(($bytes / 1GB), 2)
        })
    }
}

# 7) Export CSV + preview
$result | Sort-Object BucketName, Date | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host "CSV exported -> $OutCsv" -ForegroundColor Green
$result | Sort-Object BucketName, Date | Format-Table -AutoSize
