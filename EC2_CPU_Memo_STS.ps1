#Requires -Modules AWSPowerShell

# Output File
$OutputFile = "C:\Temp\ec2_utilization_report.csv"
if (!(Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null }
$ReportData = @()

$Regions = @("us-east-1","us-east-2","eu-north-1","eu-central-1","ap-southeast-5")

# Populate your Accounts and ProfileNames arrays below
$Accounts = @("351405419564",
    "74925547812")
$ProfileNames = @("Asia.AWS.CutEtch.Prod",
    "Asia.AWS.Manufacturing.FileStorage.Production",
    "Asia.AWS.OrangeEnergyManagementSystem.NonProd",
    "AWS_CT_Services (Master Account-Prod-NoBuild)",
    "Global-AWS-Plant-Nutanix-DR",
    "Global-AWS-PlantBackups-Prod",
    "Global-AWS-RPA-COE-NonProd",
    "Global-AWS-RPA-COE-Prod",
    "Global-Plant-AWS-BackupRestore-Prod",
    "Global.AWS.BackupStorage.Production",
    "Global.AWS.Cloud.Puppet.Production",
    "Global.AWS.CustomDev.WAS.Prod",
    "Global.AWS.DataScience.Prod",
    "Global.AWS.Engineering.HPC.Production",
    "Global.AWS.GCS.Shared.NonProd",
    "Global.AWS.GCS.Shared.Prod",
    "Global.AWS.InfraSupport.NonProd",
    "Global.AWS.PPACustomApps.NonProd",
    "Global.AWS.QualityApps.IRIS.NonProd",
    "Global.AWS.QualityApps.IRIS.Prod",
    "Global.AWS.Security.Cyberark.Prod",
    "Global.AWS.Security.Otorio.Production",
    "Global.AWS.Shopfloor.GSFS.NonProd",
    "Global.AWS.Shopfloor.IPC.NonProd",
    "Global.AWS.Shopfloor.MIRA.NonProd",
    "Global.AWS.Storage.HDC.Production",
    "Infrastructure_Test",
    "InfrastructureSDLC",
    "Linux-EC2-Build-Patch-Testing",
    "Log archive",
    "NetworkSDLC",
    "SaishankarSandbox",
    "SharedServicesSDLC")

$i = 0
foreach ($Account in $Accounts)
{
    try
    {
        $AccountName = $ProfileNames[$i]
        $i++

        $RoleArn = "arn:aws:iam::${Account}:role/AutomationReadOnlyRole"
        $Response = (Use-STSRole -RoleArn $RoleArn -RoleSessionName "EC2Utilization").Credentials

        $Credentials = New-AWSCredentials `
            -AccessKey $Response.AccessKeyId `
            -SecretKey $Response.SecretAccessKey `
            -SessionToken $Response.SessionToken

        foreach ($Region in $Regions)
        {
            $Instances = (Get-EC2Instance -Region $Region -Credential $Credentials).Instances
            if (!$Instances) { continue }

foreach ($Instance in $Instances)
{
    try
    {
        $InstanceId   = $Instance.InstanceId
        $InstanceType = $Instance.InstanceType

        $Name = "N/A"

        $Platform = $Instance.PlatformDetails

        if ($Platform -match "Windows")
        {
            $OSType = "Windows"
            $MemoryMetric = "Memory % Committed Bytes In Use"
        }
        else
        {
            $OSType = "Linux"
            $MemoryMetric = "mem_used_percent"
        }

        Write-Host "Processing Instance $InstanceId" -ForegroundColor Green

        $EndTime  = Get-Date
        $Start30d = $EndTime.AddDays(-30)
        $Start60d = $EndTime.AddDays(-60)

        # CPU 30 Days

        $CPU30Metric = Get-CWMetricStatistic `
            -Region $Region `
            -Credential $Credentials `
            -Namespace "AWS/EC2" `
            -MetricName "CPUUtilization" `
            -StartTime $Start30d `
            -EndTime $EndTime `
            -Period 3600 `
            -Statistic Maximum `
            -Dimension @(
                (New-Object Amazon.CloudWatch.Model.Dimension -Property @{
                    Name = "InstanceId"
                    Value = $InstanceId
                })
            )

        $CPU30 = ($CPU30Metric.Datapoints |
            Measure-Object -Property Maximum -Maximum).Maximum

        # CPU 60 Days

        $CPU60Metric = Get-CWMetricStatistic `
            -Region $Region `
            -Credential $Credentials `
            -Namespace "AWS/EC2" `
            -MetricName "CPUUtilization" `
            -StartTime $Start60d `
            -EndTime $EndTime `
            -Period 3600 `
            -Statistic Maximum `
            -Dimension @(
                (New-Object Amazon.CloudWatch.Model.Dimension -Property @{
                    Name = "InstanceId"
                    Value = $InstanceId
                })
            )

        $CPU60 = ($CPU60Metric.Datapoints |
            Measure-Object -Property Maximum -Maximum).Maximum

        # MEMORY 30 DAYS

        $MEM30Metric = Get-CWMetricStatistic `
            -Region $Region `
            -Credential $Credentials `
            -Namespace "CWAgent" `
            -MetricName $MemoryMetric `
            -StartTime $Start30d `
            -EndTime $EndTime `
            -Period 3600 `
            -Statistic Maximum `
            -Dimension @(
                (New-Object Amazon.CloudWatch.Model.Dimension -Property @{
                    Name = "InstanceId"
                    Value = $InstanceId
                })
            )

        $MEM30 = ($MEM30Metric.Datapoints |
            Measure-Object -Property Maximum -Maximum).Maximum

        # MEMORY 60 DAYS

        $MEM60Metric = Get-CWMetricStatistic `
            -Region $Region `
            -Credential $Credentials `
            -Namespace "CWAgent" `
            -MetricName $MemoryMetric `
            -StartTime $Start60d `
            -EndTime $EndTime `
            -Period 3600 `
            -Statistic Maximum `
            -Dimension @(
                (New-Object Amazon.CloudWatch.Model.Dimension -Property @{
                    Name = "InstanceId"
                    Value = $InstanceId
                })
            )

        $MEM60 = ($MEM60Metric.Datapoints |
            Measure-Object -Property Maximum -Maximum).Maximum

        # Null Handling

        if ($null -eq $CPU30) { $CPU30 = "NoData" }
        if ($null -eq $CPU60) { $CPU60 = "NoData" }
        if ($null -eq $MEM30) { $MEM30 = "NoData" }
        if ($null -eq $MEM60) { $MEM60 = "NoData" }

        if ($CPU30 -ne "NoData")
        {
            $CPU30 = "{0:N2}" -f [double]$CPU30
        }

        if ($CPU60 -ne "NoData")
        {
            $CPU60 = "{0:N2}" -f [double]$CPU60
        }

        if ($MEM30 -ne "NoData")
        {
            $MEM30 = "{0:N2}" -f [double]$MEM30
        }

        if ($MEM60 -ne "NoData")
        {
            $MEM60 = "{0:N2}" -f [double]$MEM60
        }

        $ReportData += [PSCustomObject]@{
            AccountId      = $Account
            AccountName    = $AccountName
            InstanceId     = $InstanceId
            Name           = $Name
            Platform       = $OSType
            InstanceType   = $InstanceType
            CPU_Max_30d    = $CPU30
            CPU_Max_60d    = $CPU60
            Memory_Max_30d = $MEM30
            Memory_Max_60d = $MEM60
            Region         = $Region
        }

        Write-Host "Completed $InstanceId" -ForegroundColor Cyan
    }
    catch
    {
        Write-Host ""
        Write-Host "---------------------------------------" -ForegroundColor Red
        Write-Host "Instance Error : $InstanceId"
        Write-Host "Account        : $Account"
        Write-Host "Region         : $Region"
        Write-Host "Message        : $($_.Exception.Message)"
        Write-Host "Line Number    : $($_.InvocationInfo.ScriptLineNumber)"
        Write-Host "Failed Command : $($_.InvocationInfo.Line)"
        Write-Host "---------------------------------------" -ForegroundColor Red
    }
}
        }
    }
    catch {
        Write-Host "Account Error : $Account"
        Write-Host $_.Exception.Message
    }
}

$ReportData | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Report Generated: $OutputFile" 