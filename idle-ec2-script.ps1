$ErrorActionPreference='Stop'
Set-AWSCredentials -AccessKey "" -SecretKey ""
try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{}
Import-Module AWS.Tools.CloudWatch
<#try{
$repo=Get-PSRepository PSGallery -ErrorAction Stop
if($repo.InstallationPolicy -ne 'Trusted'){Set-PSRepository PSGallery -InstallationPolicy Trusted}
}catch{
Register-PSRepository -Default
Set-PSRepository PSGallery -InstallationPolicy Trusted
}

if(-not(Get-PackageProvider NuGet -ErrorAction SilentlyContinue)){
Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force
}#>

if(Get-Module AWSPowerShell){Remove-Module AWSPowerShell -Force -ErrorAction SilentlyContinue}

$Region="us-east-1"
$Profile=$null
$Days=5
$PeriodSeconds=300
$CpuThreshold=5
$NetSumThresholdMB=50
$DiskOpsThreshold=500
$TagIdleKey=$null
$TagIdleValue="true"

$start=(Get-Date).AddDays(-$Days)
$end=Get-Date

$aws=@{Region=$Region}; if($Profile){$aws.ProfileName=$Profile}

Write-Host "Scanning running EC2 instances in $Region for the last $Days days..." -ForegroundColor Cyan
$instances=Get-EC2Instance @aws | Select-Object -ExpandProperty Instances | Where-Object{$_.State.Name -eq 'running'}

if(-not $instances){Write-Host "No running instances found in region $Region." -ForegroundColor Yellow;return}
function Get-Metric($Metric,$Dim,$Stat='Average'){
try{
 Get-CWMetricStatistics @aws -Namespace 'AWS/EC2' -MetricName $Metric -Dimensions $Dim -StartTime $start -EndTime $end -Period $PeriodSeconds -Statistics $Stat
}catch{
 Write-Host "Metric fetch failed: $Metric for $($Dim.Value) - $($_.Exception.Message)" -ForegroundColor DarkYellow
}
}

$result=@()
foreach($inst in $instances){
$id=$inst.InstanceId
$dim=@{Name='InstanceId';Value=$id}
$cpu=Get-Metric 'CPUUtilization' $dim 'Average'


$avgCpu=if($cpu -and $cpu.Datapoints){[Math]::Round(($cpu.Datapoints|Measure-Object Average -Average).Average,2)}else{$null}
$netTotalBytes=0


foreach($m in 'NetworkIn','NetworkOut'){
 $d=Get-Metric $m $dim 'Sum'
 if($d -and $d.Datapoints){$netTotalBytes+=($d.Datapoints|Measure-Object Sum -Sum).Sum}
}


$netTotalMB=[Math]::Round(($netTotalBytes/1MB),2)
$diskTotalOps=0

foreach($m in 'DiskReadOps','DiskWriteOps'){
 $d=Get-Metric $m $dim 'Sum'
 if($d -and $d.Datapoints){$diskTotalOps+=($d.Datapoints|Measure-Object Sum -Sum).Sum}
}


$isIdle=($avgCpu -ne $null -and $avgCpu -lt $CpuThreshold) -and ($netTotalMB -lt $NetSumThresholdMB) -and ($diskTotalOps -lt $DiskOpsThreshold)
$nameTag=($inst.Tags|Where-Object Key -eq 'Name'|Select-Object -ExpandProperty Value -ErrorAction Ignore)


$result+=[pscustomobject]@{
 InstanceId=$id
 Name=$nameTag
 State=$inst.State.Name
 InstanceType=$inst.InstanceType.Value
 LaunchTime=$inst.LaunchTime
 AvgCPUPercent=$avgCpu
 NetTotalMB=$netTotalMB
 DiskTotalOps=$diskTotalOps
 IdleRule="CPU<$CpuThreshold% & Net<$NetSumThresholdMB MB & DiskOps<$DiskOpsThreshold"
 IsIdle=$isIdle
 Region=$Region
}


if($isIdle -and $TagIdleKey){
 try{
  New-EC2Tag @aws -Resource $id -Tag @{Key=$TagIdleKey;Value=$TagIdleValue}|Out-Null
  Write-Host "Tagged $id as $TagIdleKey=$TagIdleValue" -ForegroundColor DarkGreen
 }catch{
  Write-Host "Failed tagging $id$($_.Exception.Message)" -ForegroundColor DarkYellow
 }
}

}
$idle=$result|Where-Object{$_.IsIdle}|Sort-Object AvgCPUPercent,NetTotalMB,DiskTotalOps
$active=$result|Where-Object{-not $_.IsIdle}
Write-Host ""
Write-Host "=== Idle EC2 ===" -ForegroundColor Cyan

if($idle){$idle|Format-Table InstanceId,Name,InstanceType,AvgCPUPercent,NetTotalMB,DiskTotalOps -AutoSize}
else{Write-Host "No instances matched the idle criteria." -ForegroundColor Yellow}

$outFile=Join-Path $env:USERPROFILE "Downloads\EC2_idle_report$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$result|Export-Csv -NoTypeInformation -Path $outFile
Write-Host "`nSaved detailed metrics for ALL running instances to: $outFile" -ForegroundColor Green
Write-Host ""
Write-Host "Summary: $($result.Count) running instances scanned; Idle: $($idle.Count); Active: $($active.Count)" -ForegroundColor Cyan