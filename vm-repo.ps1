#  Connect to Azure
Connect-AzAccount
#  Variables
$DaysBack  = 30
$timeGrain = [TimeSpan]::FromHours(1)
$endUtc    = (Get-Date).ToUniversalTime()
$startUtc  = $endUtc.AddDays(-$DaysBack)
$downloads = "$env:USERPROFILE\Downloads"
$rows = New-Object System.Collections.Generic.List[Object]
#  Loop through subscriptions and VMs 
foreach ($sub in Get-AzSubscription) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    foreach ($vm in Get-AzVM -Status) {
        $cpuMax = $null
        try {
            $m = Get-AzMetric -ResourceId $vm.Id `
                              -MetricName "Percentage CPU" `
                              -StartTime $startUtc `
                              -EndTime $endUtc `
                              -TimeGrain $timeGrain `
                              -Aggregation Maximum `
                              -WarningAction SilentlyContinue
            if ($m.Data) {
                $vals = $m.Data.Maximum | Where-Object { $_ -ne $null }
                if ($vals) {
                    $cpuMax = [Math]::Round(($vals | Measure-Object -Maximum).Maximum,2)
                }
            }
        }
        catch {}
        $rows.Add([PSCustomObject]@{
            SubscriptionId   = $sub.Id
            SubscriptionName = $sub.Name
            ResourceGroup    = $vm.ResourceGroupName
            VMName           = $vm.Name
            Location         = $vm.Location
            VMSize           = $vm.HardwareProfile.VmSize
            CPU_MaxPct       = $cpuMax
        })
    }
}
#  Export Report 
$utcStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmm')
$outFile  = Join-Path $downloads "Azure_VM_CPU_Max_Last${DaysBack}Days_${utcStamp}_UTC.csv"
$rows | Sort SubscriptionName,ResourceGroup,VMName |
Select SubscriptionId,SubscriptionName,ResourceGroup,VMName,Location,VMSize,CPU_MaxPct |
Export-Csv $outFile -NoTypeInformation -Encoding UTF8
Write-Host "`nReport saved to: $outFile" -ForegroundColor Green