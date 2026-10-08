
Set-AWSCredentials -AccessKey "" -SecretKey ""
# Output file
$outputFile = Join-Path $env:USERPROFILE "Downloads\tag_report_5.1$(Get-Date -Format yyyyMMdd_HHmmss).csv"
 
Write-Host "Fetching AWS resources and tags..."
 
# Run AWS CLI command
$jsonOutput = aws resourcegroupstaggingapi get-resources --output json
 
# Convert JSON to PowerShell object
$data = $jsonOutput | ConvertFrom-Json
 
$result = @()
 
foreach ($resource in $data.ResourceTagMappingList) {
 
    $arn = $resource.ResourceARN
 
    foreach ($tag in $resource.Tags) {
 
        $obj = New-Object PSObject
        $obj | Add-Member -MemberType NoteProperty -Name ResourceARN -Value $arn
        $obj | Add-Member -MemberType NoteProperty -Name TagKey -Value $tag.Key
        $obj | Add-Member -MemberType NoteProperty -Name TagValue -Value $tag.Value
 
        $result += $obj
    }
}
 
# Export to CSV
$result | Export-Csv -Path $outputFile -NoTypeInformation
 
Write-Host "Tag report exported successfully to $outputFile"