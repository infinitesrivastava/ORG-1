# AWS Credentials


$env:AWS_ACCESS_KEY_ID     = ""
$env:AWS_SECRET_ACCESS_KEY = ""
$env:AWS_SESSION_TOKEN     = ""
$env:AWS_DEFAULT_REGION    = "us-east-1"

# Output File

$OutputFile = "C:\Temp\ec2_utilization_report.csv"

# Create Temp Folder if not exists
if (!(Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" | Out-Null
}

# CSV Header
"AccountId,AccountName,InstanceId,Name,Platform,InstanceType,CPU_Max_30d,CPU_Max_60d,Memory_Max_30d,Memory_Max_60d,Region" | Out-File -FilePath $OutputFile -Encoding utf8
# Regions

$Regions = @(
    "us-east-1",
    "us-east-2",
    "eu-north-1",
    "eu-central-1"
    "ap-southeast-5"
)

# Get AWS Account ID
$AccountId = aws sts get-caller-identity `
    --query Account `
    --output text

# Get AWS Account Alias (Account Name)
$AccountName = aws iam list-account-aliases `
    --query "AccountAliases[0]" `
    --output text

if (:IsNullOrWhiteSpace($AccountName) -or $AccountName -eq "None") {
    $AccountName = "NoAlias"
}


# REGION LOOP

foreach ($Region in $Regions) {

    Write-Host "------------------------------------" -ForegroundColor Cyan
    Write-Host "Processing Region: $Region" -ForegroundColor Yellow
    Write-Host "------------------------------------" -ForegroundColor Cyan

    # Get EC2 Instances

    $InstanceData = aws ec2 describe-instances `
        --region $Region `
        --query "Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Platform:PlatformDetails,Name:Tags[?Key=='Name']|[0].Value}" `
        --output json | ConvertFrom-Json

    if (!$InstanceData) {
        Write-Host "No instances found in $Region" -ForegroundColor Red
        continue
    }

    # INSTANCE LOOP

    foreach ($Inst in $InstanceData) {
        $Instance      = $Inst.Id
        $InstanceType  = $Inst.Type
        $Platform      = $Inst.Platform
        $Name          = $Inst.Name

        # Fix Empty Name
        if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq "None") {
            $Name = "NoName"
        }

        # Detect OS Type

        if ($Platform -like "*Windows*") {
            $OSType = "Windows"
            $MemoryMetric = "Memory % Committed Bytes In Use"
        }
        else {
            $OSType = "Linux"
            $MemoryMetric = "mem_used_percent"
        }

        Write-Host "Fetching Metrics: $Instance ($OSType)" -ForegroundColor Green

        # Time Variables

        $EndTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $Start30d  = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $Start60d  = (Get-Date).AddDays(-60).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

        # CPU MAX 30 DAYS

        $CPU30 = aws cloudwatch get-metric-statistics `
            --region $Region `
            --namespace AWS/EC2 `
            --metric-name CPUUtilization `
            --dimensions Name=InstanceId,Value=$Instance `
            --start-time $Start30d `
            --end-time $EndTime `
            --period 3600 `
            --statistics Maximum `
            --query "max(Datapoints[].Maximum)" `
            --output text

        # CPU MAX 60 DAYS

        $CPU60 = aws cloudwatch get-metric-statistics `
            --region $Region `
            --namespace AWS/EC2 `
            --metric-name CPUUtilization `
            --dimensions Name=InstanceId,Value=$Instance `
            --start-time $Start60d `
            --end-time $EndTime `
            --period 3600 `
            --statistics Maximum `
            --query "max(Datapoints[].Maximum)" `
            --output text

        # MEMORY MAX 30 DAYS

        $MEM30 = aws cloudwatch get-metric-statistics `
            --region $Region `
            --namespace CWAgent `
            --metric-name "$MemoryMetric" `
            --dimensions Name=InstanceId,Value=$Instance `
            --start-time $Start30d `
            --end-time $EndTime `
            --period 3600 `
            --statistics Maximum `
            --query "max(Datapoints[].Maximum)" `
            --output text

        # MEMORY MAX 60 DAYS

        $MEM60 = aws cloudwatch get-metric-statistics `
            --region $Region `
            --namespace CWAgent `
            --metric-name "$MemoryMetric" `
            --dimensions Name=InstanceId,Value=$Instance `
            --start-time $Start60d `
            --end-time $EndTime `
            --period 3600 `
            --statistics Maximum `
            --query "max(Datapoints[].Maximum)" `
            --output text

        # Handle Null Values

        if ([string]::IsNullOrWhiteSpace($CPU30) -or $CPU30 -eq "None" -or $CPU30 -eq "null") {
            $CPU30 = "NoData"
        }

        if ([string]::IsNullOrWhiteSpace($CPU60) -or $CPU60 -eq "None" -or $CPU60 -eq "null") {
            $CPU60 = "NoData"
        }

        if ([string]::IsNullOrWhiteSpace($MEM30) -or $MEM30 -eq "None" -or $MEM30 -eq "null") {
            $MEM30 = "NoData"
        }

        if ([string]::IsNullOrWhiteSpace($MEM60) -or $MEM60 -eq "None" -or $MEM60 -eq "null") {
            $MEM60 = "NoData"
        }

        # Round Values

        if ($CPU30 -ne "NoData") {
            $CPU30 = "{0:N2}" -f [double]$CPU30
        }

        if ($CPU60 -ne "NoData") {
            $CPU60 = "{0:N2}" -f [double]$CPU60
        }

        if ($MEM30 -ne "NoData") {
            $MEM30 = "{0:N2}" -f [double]$MEM30
        }

        if ($MEM60 -ne "NoData") {
            $MEM60 = "{0:N2}" -f [double]$MEM60
        }

        # Export CSV

         $Line = "$AccountId,""$AccountName"",$Instance,""$Name"",$OSType,$InstanceType,$CPU30,$CPU60,$MEM30,$MEM60,$Region"
        Add-Content -Path $OutputFile -Value $Line

        Write-Host "Processed: $Instance ($Region)" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "Report generated successfully: $OutputFile" -ForegroundColor Green