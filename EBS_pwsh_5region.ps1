
# AWS Credentials

$env:AWS_ACCESS_KEY_ID     = ""
$env:AWS_SECRET_ACCESS_KEY = ""
$env:AWS_SESSION_TOKEN     = ""
$env:AWS_DEFAULT_REGION    = "us-east-1"


# Output File

$OutputFile = "C:\Temp\EBS_Details_Report.csv"

# Account Details

$AccountId = aws sts get-caller-identity `
    --query "Account" `
    --output text

$AccountName = aws iam list-account-aliases `
    --query "AccountAliases[0]" `
    --output text 2>$null

if ([string]::IsNullOrWhiteSpace($AccountName) -or $AccountName -eq "None") {
    $AccountName = "N/A"
}

# Get All Regions

# Process only these AWS regions
$Regions = @(
    "us-east-1",
    "us-east-2",
    "eu-north-1",
    "eu-central-1",
    "ap-southeast-5"
)

# Final Result Array

$FinalResult = @()

# Loop Through Regions

foreach ($Region in $Regions) {

    Write-Host ""
    Write-Host "Processing Region : $Region" -ForegroundColor Cyan

    # Get Volumes

    $VolumesJson = aws ec2 describe-volumes `
        --region $Region `
        --output json 2>$null

    if (-not $VolumesJson) {
        continue
    }

    $Volumes = ($VolumesJson | ConvertFrom-Json).Volumes

    foreach ($Vol in $Volumes) {

        $VolumeId = $Vol.VolumeId

        Write-Host "Traversing Volume : $VolumeId" -ForegroundColor Yellow

        # Basic Details

        $Size = $Vol.Size
        $Type = $Vol.VolumeType
        $State = $Vol.State
        $AZ = $Vol.AvailabilityZone
        $CreateTime = $Vol.CreateTime
        $Iops = $Vol.Iops
        $Throughput = $Vol.Throughput

        # Attachment Details

        $InstanceId = "N/A"
        $Device = "N/A"

        if ($Vol.Attachments.Count -gt 0) {

            $InstanceId = $Vol.Attachments[0].InstanceId
            $Device = $Vol.Attachments[0].Device
        }

        $Attachment = "$InstanceId`:$Device"

        # EC2 Name

        $EC2Name = "N/A"

        if ($InstanceId -ne "N/A") {

            $EC2Name = aws ec2 describe-instances `
                --instance-ids $InstanceId `
                --region $Region `
                --query "Reservations[0].Instances[0].Tags[?Key=='Name'].Value | [0]" `
                --output text 2>$null

            if ([string]::IsNullOrWhiteSpace($EC2Name) -or $EC2Name -eq "None") {
                $EC2Name = "N/A"
            }
        }

        # Disk Used Percentage

        $DiskUsed = "NO DATA"

        if ($InstanceId -ne "N/A") {

            $StartTime = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $EndTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Get Metric Dimensions

            $MetricJson = aws cloudwatch list-metrics `
                --namespace CWAgent `
                --metric-name disk_used_percent `
                --region $Region `
                --dimensions Name=InstanceId,Value=$InstanceId `
                --output json 2>$null

            if ($MetricJson) {

                $MetricData = $MetricJson | ConvertFrom-Json

                if ($MetricData.Metrics.Count -gt 0) {

                    $Dimensions = $MetricData.Metrics[0].Dimensions

                    $DeviceDim = ($Dimensions | Where-Object { $_.Name -eq "device" }).Value
                    $FsTypeDim = ($Dimensions | Where-Object { $_.Name -eq "fstype" }).Value
                    $PathDim   = ($Dimensions | Where-Object { $_.Name -eq "path" }).Value

                    if ($PathDim) {

                        $DiskMetric = aws cloudwatch get-metric-statistics `
                            --namespace CWAgent `
                            --metric-name disk_used_percent `
                            --dimensions `
                                Name=InstanceId,Value=$InstanceId `
                                Name=path,Value=$PathDim `
                                Name=fstype,Value=$FsTypeDim `
                                Name=device,Value=$DeviceDim `
                            --statistics Maximum `
                            --start-time $StartTime `
                            --end-time $EndTime `
                            --period 86400 `
                            --region $Region `
                            --output json 2>$null

                        if ($DiskMetric) {

                            $MetricResult = $DiskMetric | ConvertFrom-Json

                            if ($MetricResult.Datapoints.Count -gt 0) {

                                $DiskUsed = (
                                    $MetricResult.Datapoints |
                                    Measure-Object -Property Maximum -Maximum
                                ).Maximum
                            }
                        }
                    }
                }
            }
        }

        # Final Object

        $FinalResult += [PSCustomObject]@{
            AccountId          = $AccountId
            AccountName        = $AccountName
            Region             = $Region
            EC2Name            = $EC2Name
            VolumeId           = $VolumeId
            Size               = $Size
            Type               = $Type
            State              = $State
            AvailabilityZone   = $AZ
            CreateTime         = $CreateTime
            Iops               = $Iops
            Throughput         = $Throughput
            Ec2InstanceId      = $InstanceId
            Attachment         = $Attachment
            DiskUsedPercentage = $DiskUsed
        }
    }
}

# Export CSV

$FinalResult | Export-Csv `
    -Path $OutputFile `
    -NoTypeInformation

Write-Host ""
Write-Host "CSV Generated Successfully : $OutputFile" -ForegroundColor Green