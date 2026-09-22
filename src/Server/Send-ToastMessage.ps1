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

$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @(
    'SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt',
    'TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds'
)

Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config

$repeatSettings = Resolve-ToastRepeatSettings `
    -RepeatIntervalSeconds $RepeatIntervalSeconds `
    -RepeatIntervalMinutes $RepeatIntervalMinutes `
    -RepeatCount $RepeatCount

$buttonParams = @{
    ButtonText = $ButtonText
    ButtonArguments = $ButtonArguments
}

if (-not [string]::IsNullOrWhiteSpace([string]$ButtonActivationType)) {
    $buttonParams.ButtonActivationType = $ButtonActivationType
}

$buttonSettings = Resolve-ToastButtonSettings @buttonParams

$soundValue = if (
    $PSBoundParameters.ContainsKey('Sound') -and
    -not [string]::IsNullOrWhiteSpace([string]$Sound)
) {
    [string]$Sound
} else {
    $null
}

$params = @{
    GroupName = $GroupName
    Title = $Title
    Body = $Body
    ExpiresUtc = if ($ExpiresUtc) { $ExpiresUtc.ToUniversalTime() } else { $null }
    AppLogoPath = if ([string]::IsNullOrWhiteSpace([string]$AppLogoPath)) { $null } else { [string]$AppLogoPath }
    HeroImagePath = if ([string]::IsNullOrWhiteSpace([string]$HeroImagePath)) { $null } else { [string]$HeroImagePath }
    Sound = $soundValue
    IsUrgent = $Urgent.IsPresent
    RepeatIntervalSeconds = if ($null -ne $repeatSettings) { $repeatSettings.RepeatIntervalSeconds } else { $null }
    RepeatCount = if ($null -ne $repeatSettings) { $repeatSettings.RepeatCount } else { $null }
    ButtonText = if ($null -ne $buttonSettings) { $buttonSettings.ButtonText } else { $null }
    ButtonArguments = if ($null -ne $buttonSettings) { $buttonSettings.ButtonArguments } else { $null }
    ButtonActivationType = if ($null -ne $buttonSettings) { $buttonSettings.ButtonActivationType } else { $null }
}

$sql = @'
EXEC dbo.usp_QueueToastMessage
    @GroupName,
    @Title,
    @Body,
    @ExpiresUtc,
    @AppLogoPath,
    @HeroImagePath,
    @Sound,
    @IsUrgent,
    @RepeatIntervalSeconds,
    @RepeatCount,
    @ButtonText,
    @ButtonArguments,
    @ButtonActivationType
'@

$result = Invoke-ToastSql `
    -ConnectionString $conn `
    -SqlCredential $sqlCredential `
    -CommandText $sql `
    -Parameters $params `
    -CommandTimeoutSeconds $config.CommandTimeoutSeconds

if ($null -eq $result -or $result.Rows.Count -eq 0) {
    throw 'Queue toast message SQL command returned no result set.'
}

Write-Output "Queued message $($result.Rows[0].MessageId) for group '$GroupName'."
