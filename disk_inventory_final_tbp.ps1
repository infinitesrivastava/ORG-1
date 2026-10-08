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

$ErrorActionPreference = "SilentlyContinue"

# Output File

$OutputFile = "C:\Temp\Azure_Disk_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

# Final Result Array

$FinalResult = @()

# Global HashMaps

$VMOSMap = @{}
$DiskUsageMap = @{}

# Get All Subscriptions

$Subscriptions = Get-AzSubscription

foreach ($Sub in $Subscriptions) {

    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor DarkGray
    Write-Host "Processing Subscription : $($Sub.Name)" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor DarkGray

    try {

        Set-AzContext -SubscriptionId $Sub.Id | Out-Null

        Start-Sleep -Seconds 2
    }
    catch {

        Write-Host "Failed to set context for subscription : $($Sub.Name)" -ForegroundColor Red
        continue
    }

    # STEP 1 - VM INVENTORY

    Write-Host ""
    Write-Host "Fetching VM Inventory..." -ForegroundColor Green

    try {

        $VMs = Get-AzVM -Status

        foreach ($VM in $VMs) {

            $VMName = $VM.Name.ToLower()

            try {

                $OSType = $VM.StorageProfile.OsDisk.OsType.ToString()

                if ([string]::IsNullOrWhiteSpace($OSType)) {

                    $OSType = "Unknown"
                }
            }
            catch {

                $OSType = "Unknown"
            }

            $VMOSMap[$VMName] = $OSType
        }
    }
    catch {

        Write-Host "Failed to fetch VM inventory." -ForegroundColor Red
    }

    # STEP 2 - LAW QUERY

    Write-Host ""
    Write-Host "Fetching LAW Workspaces..." -ForegroundColor Green

    try {

        $LAWs = Get-AzOperationalInsightsWorkspace
    }
    catch {

        Write-Host "Unable to fetch LAW workspaces." -ForegroundColor Red
        $LAWs = @()
    }

    foreach ($LAW in $LAWs) {

        Write-Host ""
        Write-Host "Traversing LAW : $($LAW.Name)" -ForegroundColor Yellow

        $WorkspaceId = $LAW.CustomerId

        # WINDOWS QUERY

        $WindowsKQL = @"
Perf
| where TimeGenerated > ago(30d)
| where ObjectName == "LogicalDisk"
| where CounterName == "% Free Space"
| summarize MaxFree=max(CounterValue) by Computer
| extend disk_used_percentage = round(100 - MaxFree,2)
| project Computer,disk_used_percentage
"@

        try {

            $WindowsResults = Invoke-AzOperationalInsightsQuery `
                -WorkspaceId $WorkspaceId `
                -Query $WindowsKQL `
                -Wait 300 `
                -ErrorAction Stop

            foreach ($Row in $WindowsResults.Results) {

                $VMName = $Row.Computer.ToLower()

                $DiskUsageMap[$VMName] = [PSCustomObject]@{

                    DiskUsedPercent = [math]::Round($Row.disk_used_percentage,2)
                    LAWName         = $LAW.Name
                }
            }
        }
        catch {

            Write-Host "Windows query failed for LAW : $($LAW.Name)" -ForegroundColor Red
        }

        # LINUX QUERY

        $LinuxKQL = @"
Perf
| where TimeGenerated > ago(30d)
| where ObjectName == "Logical Disk"
| where CounterName == "% Used Space"
| summarize disk_used_percentage=max(CounterValue) by Computer
| project Computer,disk_used_percentage
"@

        try {

            $LinuxResults = Invoke-AzOperationalInsightsQuery `
                -WorkspaceId $WorkspaceId `
                -Query $LinuxKQL `
                -Wait 300 `
                -ErrorAction Stop

            foreach ($Row in $LinuxResults.Results) {

                $VMName = $Row.Computer.ToLower()

                $DiskUsageMap[$VMName] = [PSCustomObject]@{

                    DiskUsedPercent = [math]::Round($Row.disk_used_percentage,2)
                    LAWName         = $LAW.Name
                }
            }
        }
        catch {

            Write-Host "Linux query failed for LAW : $($LAW.Name)" -ForegroundColor Red
        }
    }

    # STEP 3 - DISK INVENTORY

    Write-Host ""
    Write-Host "Fetching Disk Inventory..." -ForegroundColor Green

    try {

        $Disks = Get-AzDisk -ErrorAction Stop
    }
    catch {

        Write-Host "Failed to fetch disks in subscription : $($Sub.Name)" -ForegroundColor Red
        continue
    }

    foreach ($Disk in $Disks) {

        Write-Host "Traversing Disk : $($Disk.Name)" -ForegroundColor Cyan

        # Default Values

        $ManagedBy = "N/A"
        $OS = "N/A"
        $LAWName = "NO LAW MATCH"

        $DiskUsedPercent = "NO DATA"
        $DiskFree = "NO DATA"
        $DiskUsed = "NO DATA"
        $DiskTotal = "NO DATA"

        # Managed By

        if ($Disk.ManagedBy) {

            $ManagedBy = ($Disk.ManagedBy -split "/")[-1]

            $LookupName = $ManagedBy.ToLower()

            # OS Lookup

            if ($VMOSMap.ContainsKey($LookupName)) {

                $OS = $VMOSMap[$LookupName]
            }

            # Disk Usage Lookup

            if ($DiskUsageMap.ContainsKey($LookupName)) {

                $DiskUsedPercent = $DiskUsageMap[$LookupName].DiskUsedPercent

                # Total Disk Size from Azure

                $DiskTotal = [math]::Round($Disk.DiskSizeGB,2)

                # Used Disk in GB

                $DiskUsed = [math]::Round(($DiskTotal * $DiskUsedPercent) / 100,2)

                # Free Disk in GB

                $DiskFree = [math]::Round($DiskTotal - $DiskUsed,2)

                $LAWName = $DiskUsageMap[$LookupName].LAWName
            }
        }

        # Availability Zone

        $AvailabilityZone = ($Disk.Zones -join ",")

        if ([string]::IsNullOrWhiteSpace($AvailabilityZone)) {

            $AvailabilityZone = "N/A"
        }

        # Final Output

        $FinalResult += [PSCustomObject]@{

            SubscriptionId       = $Sub.Id
            SubscriptionName     = $Sub.Name
            DiskID               = ($Disk.Id -split "/")[-1]
            Name                 = $Disk.Name
            DiskType             = $Disk.Sku.Name
            AvailabilityZone     = $AvailabilityZone
            TimeCreated          = $Disk.TimeCreated
            State                = $Disk.DiskState
            SizeGB               = $Disk.DiskSizeGB
            Iops                 = $Disk.DiskIOPSReadWrite
            ThroughputMBps       = $Disk.DiskMBpsReadWrite
            ManagedBy            = $ManagedBy
            OS                   = $OS
            LAWName              = $LAWName
            disk_free_GB         = $DiskFree
            disk_used_GB         = $DiskUsed
            disk_total_GB        = $DiskTotal
            disk_used_percentage = $DiskUsedPercent
        }
    }
}

# EXPORT CSV

try {

    if (!(Test-Path "C:\Temp")) {

        New-Item -Path "C:\Temp" -ItemType Directory | Out-Null
    }

    $FinalResult | Export-Csv `
        -Path $OutputFile `
        -NoTypeInformation `
        -Force

    Write-Host ""
    Write-Host "CSV Generated Successfully : $OutputFile" -ForegroundColor Green
}
catch {

    Write-Host "Failed to export CSV." -ForegroundColor Red
}