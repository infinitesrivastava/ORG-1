$TenantId = ""
$ClientId = ""
$ClientSecret = ""
$SecurePassword = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential(
    $ClientId,
    $SecurePassword
)
Connect-AzAccount `
    -ServicePrincipal `
    -Tenant $TenantId `
    -Credential $Credential
 
 
# OUTPUT FILE
 
$OutputFile = "C:\Temp\Azure_VM_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
 
# INITIALIZE RESULTS
 
$Results = [System.Collections.Generic.List[Object]]::new()
 
# DATE RANGE
 
$EndTime = Get-Date
$Start30 = (Get-Date).AddDays(-30)
$Start60 = (Get-Date).AddDays(-60)
 
try {
    $Subscriptions = Get-AzSubscription -ErrorAction Stop |
        Where-Object { $_.State -eq "Enabled" }
}
catch {
    Write-Host "Failed to retrieve Azure subscriptions." `
        -ForegroundColor Red
 
    Write-Host "Error: $($_.Exception.Message)" `
        -ForegroundColor Red
 
    return
}
 
if (-not $Subscriptions) {
    Write-Host "No enabled Azure subscriptions were found." `
        -ForegroundColor Yellow
 
    return
}
 
Write-Host ""
Write-Host "Total Enabled Subscriptions Found: $($Subscriptions.Count)" `
    -ForegroundColor Green
 
Write-Host ""
 
# ---------------------------------------------------------------------
# SUBSCRIPTION LOOP
# ---------------------------------------------------------------------
 
foreach ($Subscription in $Subscriptions) {
 
    Write-Host "============================================================" `
        -ForegroundColor DarkGray
 
    Write-Host "Processing Subscription: $($Subscription.Name)" `
        -ForegroundColor Yellow
 
    Write-Host "Subscription ID: $($Subscription.Id)" `
        -ForegroundColor DarkYellow
 
    Write-Host "Tenant ID: $($Subscription.TenantId)" `
        -ForegroundColor DarkYellow
 
    # -----------------------------------------------------------------
    # SET SUBSCRIPTION CONTEXT
    # -----------------------------------------------------------------
 
    try {
        $Context = Set-AzContext `
            -SubscriptionId $Subscription.Id `
            -TenantId $Subscription.TenantId `
            -ErrorAction Stop
 
        if (-not $Context) {
            throw "Azure subscription context could not be created."
        }
    }
    catch {
        Write-Host "Failed to access subscription: $($Subscription.Name)" `
            -ForegroundColor Red
 
        Write-Host "Error: $($_.Exception.Message)" `
            -ForegroundColor Red
 
        Write-Host "Skipping this subscription..." `
            -ForegroundColor Yellow
 
        Write-Host ""
 
        continue
    }
# GET ALL VMS
 
$VMs = Get-AzVM
 
# VM LOOP
 
foreach ($VM in $VMs) {
 
    Write-Host "Fetching Metrics For VM: $($VM.Name)" -ForegroundColor Cyan
 
    $VMId = $VM.Id
 
    # SMALL DELAY TO AVOID API THROTTLING
 
    Start-Sleep -Milliseconds 200
 
    # CPU MAX 30 DAYS
 
    $cpu30 = "NA"
 
    try {
 
        $cpu30Metric = Get-AzMetric `
            -ResourceId $VMId `
            -MetricName "Percentage CPU" `
            -StartTime $Start30 `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -AggregationType Maximum `
            -ErrorAction SilentlyContinue
 
        if ($cpu30Metric.Data) {
 
            $cpu30Value = (
                $cpu30Metric.Data |
                Where-Object { $_.Maximum -ne $null } |
                Measure-Object -Property Maximum -Maximum
            ).Maximum
 
            if ($cpu30Value -ne $null) {
                $cpu30 = [math]::Round($cpu30Value,2)
            }
        }
    }
    catch {}
 
    # CPU MAX 60 DAYS
 
    $cpu60 = "NA"
 
    try {
 
        $cpu60Metric = Get-AzMetric `
            -ResourceId $VMId `
            -MetricName "Percentage CPU" `
            -StartTime $Start60 `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -AggregationType Maximum `
            -ErrorAction SilentlyContinue
 
        if ($cpu60Metric.Data) {
 
            $cpu60Value = (
                $cpu60Metric.Data |
                Where-Object { $_.Maximum -ne $null } |
                Measure-Object -Property Maximum -Maximum
            ).Maximum
 
            if ($cpu60Value -ne $null) {
                $cpu60 = [math]::Round($cpu60Value,2)
            }
        }
    }
    catch {}
 
    # MEMORY UTILIZATION MAX 30 DAYS
    # Utilization = 100 - Available Memory %
 
    $mem30 = "NA"
 
    try {
 
        $mem30Metric = Get-AzMetric `
            -ResourceId $VMId `
            -MetricName "Available Memory Percentage" `
            -StartTime $Start30 `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -AggregationType Minimum `
            -ErrorAction SilentlyContinue
 
        if ($mem30Metric.Data) {
 
            $minAvailable30 = (
                $mem30Metric.Data |
                Where-Object { $_.Minimum -ne $null } |
                Measure-Object -Property Minimum -Minimum
            ).Minimum
 
            if ($minAvailable30 -ne $null) {
 
                $mem30Value = 100 - $minAvailable30
                $mem30 = [math]::Round($mem30Value,2)
            }
        }
    }
    catch {}
 
    # MEMORY UTILIZATION MAX 60 DAYS
 
    $mem60 = "NA"
 
    try {
 
        $mem60Metric = Get-AzMetric `
            -ResourceId $VMId `
            -MetricName "Available Memory Percentage" `
            -StartTime $Start60 `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -AggregationType Minimum `
            -ErrorAction SilentlyContinue
 
        if ($mem60Metric.Data) {
 
            $minAvailable60 = (
                $mem60Metric.Data |
                Where-Object { $_.Minimum -ne $null } |
                Measure-Object -Property Minimum -Minimum
            ).Minimum
 
            if ($minAvailable60 -ne $null) {
 
                $mem60Value = 100 - $minAvailable60
                $mem60 = [math]::Round($mem60Value,2)
            }
        }
    }
    catch {}
 
    # ADD RESULTS
 
    $Results.Add([PSCustomObject]@{
        SubscriptionID           = $Subscription.Id
        Subscription_Name        = $Subscription.Name
        VMName                   = $VM.Name
        ResourceGroup            = $VM.ResourceGroupName
        Region                   = $VM.Location
        VMSize                   = $VM.HardwareProfile.VmSize
        MaxCPU_30Days_Percentage = $cpu30
        MaxCPU_60Days_Percentage = $cpu60
        MaxMem_30Days_Percentage = $mem30
        MaxMem_60Days_Percentage = $mem60
    })
}
}
 
# EXPORT CSV
 
$Results | Export-Csv $OutputFile -NoTypeInformation -Encoding UTF8
 
# COMPLETED
 
Write-Host ""
Write-Host "Report Generated Successfully: $OutputFile" -ForegroundColor Green