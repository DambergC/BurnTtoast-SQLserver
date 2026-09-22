[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ConfigPath,
 [Parameter(Mandatory)][string]$GroupName,
 [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
 [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
 [datetime]$ExpiresUtc
)
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config=Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt','TrustServerCertificate','CommandTimeoutSeconds')
Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn=Get-ToastConnectionString $config
$sql='EXEC dbo.usp_QueueToastMessage @GroupName,@Title,@Body,@ExpiresUtc'
$params=@{GroupName=$GroupName;Title=$Title;Body=$Body;ExpiresUtc=if($ExpiresUtc){$ExpiresUtc.ToUniversalTime()}else{$null}}
$result=Invoke-ToastSql -ConnectionString $conn -CommandText $sql -Parameters $params -CommandTimeoutSeconds $config.CommandTimeoutSeconds
Write-Output "Queued message $($result.MessageId) for group '$GroupName'."
