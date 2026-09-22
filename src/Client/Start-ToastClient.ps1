[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Register,[switch]$Once,[int]$PollSeconds=30)
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config=Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','ClientName','ClientGroups','InternalPowerShellRepository','Encrypt','TrustServerCertificate','CommandTimeoutSeconds') -NullableProperties @('ClientName','InternalPowerShellRepository') -ResolveClientName
if(-not (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue)) {
    if($config.InternalPowerShellRepository){Install-Module BurntToast -Repository $config.InternalPowerShellRepository -Scope CurrentUser -Force}
    else {Write-Warning 'BurntToast is not installed. Install it from your approved repository.'}
    Import-Module BurntToast -ErrorAction Stop
}
Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn=Get-ToastConnectionString $config
$computer=$config.ClientName
function Invoke-Registration {
    $sql="IF NOT EXISTS(SELECT 1 FROM dbo.ToastClient WHERE ComputerName=@ComputerName) INSERT dbo.ToastClient(ComputerName) VALUES(@ComputerName); DECLARE @ClientId int=(SELECT ClientId FROM dbo.ToastClient WHERE ComputerName=@ComputerName); MERGE dbo.ToastGroup AS t USING (SELECT @GroupName GroupName) s ON t.GroupName=s.GroupName WHEN NOT MATCHED THEN INSERT(GroupName) VALUES(s.GroupName); INSERT dbo.ToastClientGroup(ClientId,GroupId) SELECT @ClientId,GroupId FROM dbo.ToastGroup g WHERE g.GroupName=@GroupName AND NOT EXISTS(SELECT 1 FROM dbo.ToastClientGroup x WHERE x.ClientId=@ClientId AND x.GroupId=g.GroupId);"
    foreach($g in $config.ClientGroups){Invoke-ToastSql $conn $sql @{ComputerName=$computer;GroupName=$g} -NonQuery}
}
if($Register){Invoke-Registration;Write-Output "Registered $computer";if($Once){return}}
function Invoke-Poll {
    $rows=Invoke-ToastSql $conn 'EXEC dbo.usp_GetPendingToast @ComputerName' @{ComputerName=$computer}
    foreach($row in $rows){try{New-BurntToastNotification -Text @($row.Title,$row.Body);Invoke-ToastSql $conn 'EXEC dbo.usp_RecordToastDelivery @ComputerName,@MessageId,@Status,@ErrorMessage' @{ComputerName=$computer;MessageId=$row.MessageId;Status='Delivered';ErrorMessage=$null} -NonQuery}catch{Invoke-ToastSql $conn 'EXEC dbo.usp_RecordToastDelivery @ComputerName,@MessageId,@Status,@ErrorMessage' @{ComputerName=$computer;MessageId=$row.MessageId;Status='Failed';ErrorMessage=$_.Exception.Message} -NonQuery}}
}
do{Invoke-Poll;if($Once){break};Start-Sleep -Seconds $PollSeconds}while($true)
