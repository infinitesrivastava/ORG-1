# Login
#Connect-AzAccount

$subscriptionName = $context.Subscription.Name
$subscriptionId   = $context.Subscription.Id

# Output file
$OutputFile = Join-Path $env:USERPROFILE "Downloads\VM-Health-Status-$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"

#Backup Data
Write-Host "Fetching backup details..." -ForegroundColor Yellow

$allBackupItems = @()

$vaults = Get-AzRecoveryServicesVault

foreach ($vault in $vaults) {
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $items = Get-AzRecoveryServicesBackupItem `
        -BackupManagementType AzureVM `
        -WorkloadType AzureVM `
        -ErrorAction SilentlyContinue

    $allBackupItems += $items
}

#VM Details

$vms = Get-AzVM

$vmReport = @()

foreach ($vm in $vms) {

    Write-Host "Processing VM:" $vm.Name -ForegroundColor Cyan

    # Instance view
    $vmStatus = Get-AzVM -ResourceGroupName $vm.ResourceGroupName `
                        -Name $vm.Name -Status

    # Power State
    $powerState = ($vmStatus.Statuses | Where-Object {
        $_.Code -match "PowerState"
    }).DisplayStatus

    # Provisioning state
    $provState = $vm.ProvisioningState

    # Instance status
    $instanceStatus = ($vmStatus.Statuses | Where-Object {
        $_.Code -match "ProvisioningState"
    }).DisplayStatus

    # VM Agent
    if ($vmStatus.VMAgent -and $vmStatus.VMAgent.Statuses) {
        $vmAgentStatus = $vmStatus.VMAgent.Statuses[0].DisplayStatus
    } else {
        $vmAgentStatus = "Not Installed"
    }

    # Resource Health
    try {
        $resourceHealth = (Get-AzResourceHealth -ResourceId $vm.Id -ErrorAction Stop).Properties.AvailabilityState
    } catch {
        $resourceHealth = "Unknown"
    }

    # Extensions
    try {
        $ext = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name
        $extensionStatus = ($ext | Select-Object -ExpandProperty ProvisioningState) -join ", "
    } catch {
        $extensionStatus = "Error"
    }

    # Disks
    $osDisk = $vm.StorageProfile.OsDisk.Name
    $dataDisks = ($vm.StorageProfile.DataDisks | Select-Object -ExpandProperty Name) -join ", "

    #Backup Status
    $backupItem = $allBackupItems | Where-Object {
        $_.SourceResourceId -eq $vm.Id
    }

    if ($backupItem) {
        $backupStatus     = $backupItem.ProtectionStatus
        $lastBackupStatus = $backupItem.LastBackupStatus
        $lastBackupTime   = $backupItem.LastBackupTime
    } else {
        $backupStatus     = "Not Enabled"
        $lastBackupStatus = ""
        $lastBackupTime   = ""
    }

   # Logic of OK and NOT OK

    if (
        $powerState -eq "VM running" -and
        $provState -eq "Succeeded" -and
        ($vmAgentStatus -match "Ready")
    ) {
        $overallStatus = "OK"
    } else {
        $overallStatus = "NOT OK"
    }

    # Create object
    $vmReport += [PSCustomObject]@{
        SubscriptionName = $subscriptionName
        SubscriptionId   = $subscriptionId
        VMName           = $vm.Name
        ResourceGroup    = $vm.ResourceGroupName
        Location         = $vm.Location
        PowerState       = $powerState
        ProvisioningState= $provState
        InstanceStatus   = $instanceStatus
        #ResourceHealth   = $resourceHealth
        VMAgentStatus    = $vmAgentStatus
        ExtensionStatus  = $extensionStatus
        OSDisk           = $osDisk
        DataDisks        = $dataDisks
        BackupStatus     = $backupStatus
        LastBackupStatus = $lastBackupStatus
        LastBackupTime   = $lastBackupTime
        OverallStatus    = $overallStatus
    }
}

# Export CSV
$vmReport | Export-Csv -Path $OutputFile -NoTypeInformation

Write-Host "`n Report Generated: $OutputFile" -ForegroundColor Green
