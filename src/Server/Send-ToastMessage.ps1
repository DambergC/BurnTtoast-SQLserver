[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ConfigPath,
 [Parameter(Mandatory)][string]$GroupName,
 [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
 [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
 [datetime]$ExpiresUtc,
 [string]$AppLogoPath,
 [string]$HeroImagePath,
 [ValidateSet('Default','IM','Mail','Reminder','SMS','Alarm','Alarm2','Alarm3','Alarm4','Alarm5','Alarm6','Alarm7','Alarm8','Alarm9','Alarm10','Call','Call2','Call3','Call4','Call5','Call6','Call7','Call8','Call9','Call10')][string]$Sound,
 [switch]$Urgent,
 [Nullable[int]]$RepeatIntervalSeconds,
 [Nullable[int]]$RepeatIntervalMinutes,
 [Nullable[int]]$RepeatCount,
 [Parameter(HelpMessage='Optional text shown on a single toast action button.')][string]$ButtonText,
 [Parameter(HelpMessage='Optional button argument, typically an absolute URL or protocol URI.')][string]$ButtonArguments,
 [Parameter(HelpMessage='Button activation type. Use Protocol to open a URI or Dismiss to close the toast.')][ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType
)
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config=Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds')
Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn=Get-ToastConnectionString $config
$sqlCredential=Get-ToastSqlCredential $config
$repeatSettings = Resolve-ToastRepeatSettings -RepeatIntervalSeconds $RepeatIntervalSeconds -RepeatIntervalMinutes $RepeatIntervalMinutes -RepeatCount $RepeatCount
$buttonSettings = Resolve-ToastButtonSettings -ButtonText $ButtonText -ButtonArguments $ButtonArguments -ButtonActivationType $ButtonActivationType
$sql='EXEC dbo.usp_QueueToastMessage @GroupName,@Title,@Body,@ExpiresUtc,@AppLogoPath,@HeroImagePath,@Sound,@IsUrgent,@RepeatIntervalSeconds,@RepeatCount,@ButtonText,@ButtonArguments,@ButtonActivationType'
$params=@{
    GroupName=$GroupName
    Title=$Title
    Body=$Body
    ExpiresUtc=if($ExpiresUtc){$ExpiresUtc.ToUniversalTime()}else{$null}
    AppLogoPath=if([string]::IsNullOrWhiteSpace($AppLogoPath)){$null}else{$AppLogoPath}
    HeroImagePath=if([string]::IsNullOrWhiteSpace($HeroImagePath)){$null}else{$HeroImagePath}
    Sound=if([string]::IsNullOrWhiteSpace($Sound)){$null}else{$Sound}
    IsUrgent=$Urgent.IsPresent
    RepeatIntervalSeconds=$repeatSettings.RepeatIntervalSeconds
    RepeatCount=$repeatSettings.RepeatCount
    ButtonText=$buttonSettings.ButtonText
    ButtonArguments=$buttonSettings.ButtonArguments
    ButtonActivationType=$buttonSettings.ButtonActivationType
}
$result=Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential -CommandText $sql -Parameters $params -CommandTimeoutSeconds $config.CommandTimeoutSeconds
Write-Output "Queued message $($result.MessageId) for group '$GroupName'."
