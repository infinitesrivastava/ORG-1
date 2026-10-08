# Install-Module -Name Az -Scope CurrentUser -AllowClobber -Force
# Install-Module -Name Az.Billing -Force
 
# Connect
if (-not (Get-AzContext)) {
    Connect-AzAccount
}
 
#Variables
$StartTime = (Get-Date).ToUniversalTime().AddDays(-30)
$EndTime   = (Get-Date).ToUniversalTime()
$outFile   = "./Storage5.csv"
 
#Size-formatting
function Format-SizeIec {
    param([double]$bytes)
    if ($null -eq $bytes -or $bytes -eq 0) { return '0 B' }
    $units = @('B','KiB','MiB','GiB','TiB','PiB')
    $i = 0
    while ($bytes -ge 1024 -and $i -lt ($units.Count-1)) {
        $bytes /= 1024
        $i++
    }
    $value = if ($i -eq 0) { [math]::Round($bytes,0) } else { [math]::Round($bytes, 3) }
    return "$value $($units[$i])"
}
 
#Cost-Consumption
$consumption = @{}
$consumptionIndex = @{}
 
function Get-StorageCost30Days {
    param($SubscriptionId, $StorageResourceId)
 
    if (-not $consumption.ContainsKey($SubscriptionId)) {
 
        Write-Host "Fetching consumption for subscription $SubscriptionId..." -ForegroundColor Yellow
 
        $usage = Get-AzConsumptionUsageDetail `
            -StartDate $StartTime.Date `
            -EndDate $EndTime.Date `
            -ErrorAction SilentlyContinue
 
        $consumption[$SubscriptionId] = $usage
        $index = @{}
        foreach ($u in $usage) {
            if ($u.InstanceId) {
                if (-not $index.ContainsKey($u.InstanceId)) {
                    $index[$u.InstanceId] = 0
                }
                $index[$u.InstanceId] += [decimal]$u.PretaxCost
            }
        }
 
        $consumptionIndex[$SubscriptionId] = $index
    }
 
    $index = $consumptionIndex[$SubscriptionId]
 
    if ($index.ContainsKey($StorageResourceId)) {
        return [math]::Round([double]$index[$StorageResourceId], 4)
    }
 
    return 0
}
 
#Capacity-Calculation

function Get-Capacity {
    param($ResourceId, $MetricName)
 
    try {
        $metric = Get-AzMetric -ResourceId $ResourceId `
            -MetricName $MetricName `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -AggregationType Average `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop
 
        if ($metric.Data) {
            $valid = $metric.Data | Where-Object { $null -ne $_.Average }
            if ($valid.Count -gt 0) {
                return [math]::Round(($valid | Measure-Object Average -Average).Average, 3)
            }
        }
        return 0
    }
    catch {
        return 0
    }
}
 
#Transaction-Calculation
function Get-Transactions {
    param($ResourceId)
 
    try {
        $metric = Get-AzMetric -ResourceId $ResourceId `
            -MetricName "Transactions" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -TimeGrain (New-TimeSpan -Days 1) `
            -AggregationType Total `
            -ErrorAction Stop
 
        if ($metric.Data) {
            return [long][math]::Round(($metric.Data | Measure-Object Total -Sum).Sum, 0)
        }
        return 0
    }
    catch {
        return 0
    }
}
 
#Resume in csv

$processed = [System.Collections.Generic.HashSet[string]]::new()
$useAppend = Test-Path $outFile
$processedThisRun = 0
 
if ($useAppend) {
    Write-Host "Resuming from existing CSV..." -ForegroundColor Cyan
 
    Import-Csv $outFile | ForEach-Object {
        $key = "$($_.SubscriptionId)|$($_.StorageAccount)"
        [void]$processed.Add($key)
    }
}
 
#Main

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
 
foreach ($sub in $subscriptions) {
 
    Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
 
    $storageAccounts = Get-AzStorageAccount
 
    foreach ($sa in $storageAccounts) {
 
        $accountName = $sa.StorageAccountName
        $key = "$($sub.Id)|$accountName"
 
        if ($processed.Contains($key)) {
            Write-Host "  → $accountName (skipped)" -ForegroundColor Gray
            continue
        }
 
        try {
            Write-Host "  → $accountName" -ForegroundColor DarkCyan -NoNewline
 
            $baseRid = $sa.Id
 
            # Capacity
            $usedBytes  = Get-Capacity -ResourceId $baseRid -MetricName "UsedCapacity"
            $blobBytes  = Get-Capacity -ResourceId "$baseRid/blobServices/default"  -MetricName "BlobCapacity"
            $fileBytes  = Get-Capacity -ResourceId "$baseRid/fileServices/default"  -MetricName "FileCapacity"
            $queueBytes = Get-Capacity -ResourceId "$baseRid/queueServices/default" -MetricName "QueueCapacity"
            $tableBytes = Get-Capacity -ResourceId "$baseRid/tableServices/default" -MetricName "TableCapacity"
            $txCount = Get-Transactions -ResourceId $baseRid
            $cost = Get-StorageCost30Days -SubscriptionId $sub.Id -StorageResourceId $baseRid
 
            $row = [PSCustomObject]@{
                SubscriptionName          = $sub.Name
                SubscriptionId            = $sub.Id
                ResourceGroup             = $sa.ResourceGroupName
                StorageAccount            = $accountName
                Location                  = $sa.Location
                Kind                      = $sa.Kind
                SkuName                   = $sa.Sku.Name
                AccessTier                = $sa.AccessTier
                UsedCapacity              = Format-SizeIec $usedBytes
                BlobCapacity              = Format-SizeIec $blobBytes
                FileCapacity              = Format-SizeIec $fileBytes
                QueueCapacity             = Format-SizeIec $queueBytes
                TableCapacity             = Format-SizeIec $tableBytes
                TotalTransactions_30Days  = $txCount
                EstimatedCost_30Days      = $cost
            }
 
            if ($useAppend) {
                $row | Export-Csv -Path $outFile -Append -NoTypeInformation -Encoding UTF8
            } else {
                $row | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
                $useAppend = $true
            }
 
            $processedThisRun++
            Write-Host " ... done" -ForegroundColor Green
 
            Start-Sleep -Milliseconds 10
        }
        catch {
            Write-Host " ... ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
 
#Output
if (Test-Path $outFile) {
    $data = Import-Csv $outFile
    $data | Sort-Object SubscriptionName, StorageAccount |
        Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
 
    Write-Host "`nReport completed!" -ForegroundColor Green
    Write-Host "Processed this run   : $processedThisRun" -ForegroundColor Green
    Write-Host "Total accounts in CSV: $($data.Count)" -ForegroundColor Green
    Write-Host "CSV With all data : $outFile" -ForegroundColor Green
}