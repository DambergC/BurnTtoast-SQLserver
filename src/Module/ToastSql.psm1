Set-StrictMode -Version Latest

$script:ToastSupportedImageContentTypes = @{
    'image/png' = '.png'
    'image/jpeg' = '.jpg'
    'image/gif' = '.gif'
    'image/bmp' = '.bmp'
}
$script:ToastMaxImageBytes = 5MB
$script:ToastTemporaryFilePrefix = 'BurnTtoast-SQLserver-'
$script:ToastTemporaryDirectoryName = 'BurnTtoast-SQLserver'
$script:ToastTemporaryFileRetentionMinutes = 60
$script:ToastSupportedDisplayModes = @('BurntToast','Wpf','AppDeployToolkit')
$script:ToastDependencyOptions = @{
    InternalPowerShellRepository = $null
    AppDeployToolkitModulePath = $null
}
$script:ToastSupportedWpfProtocolSchemes = @('http','https','mailto')
$script:ToastSupportedScenarios = @('Default','Reminder','Alarm','IncomingCall')
$script:ToastSqlNullParameterDefinitions = @{
    GroupName = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 128 }
    Title = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    Body = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 4000 }
    AppLogoPath = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 1024 }
    HeroImagePath = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 1024 }
    AppLogoBytes = @{ SqlDbType = [System.Data.SqlDbType]::VarBinary; Size = -1 }
    HeroImageBytes = @{ SqlDbType = [System.Data.SqlDbType]::VarBinary; Size = -1 }
    AppLogoContentType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 100 }
    HeroImageContentType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 100 }
    Sound = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    IsUrgent = @{ SqlDbType = [System.Data.SqlDbType]::Bit }
    RepeatIntervalSeconds = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    RepeatCount = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    ButtonText = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    ButtonArguments = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 2048 }
    MessageId = @{ SqlDbType = [System.Data.SqlDbType]::BigInt }
    LeaseId = @{ SqlDbType = [System.Data.SqlDbType]::UniqueIdentifier }
    ExpiresUtc = @{ SqlDbType = [System.Data.SqlDbType]::DateTime2 }
    ButtonActivationType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    DisplayMode = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    Scenario = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
}

function Get-ToastSqlCredentialValues {
    param(
        [Parameter(Mandatory)]$SqlCredential,
        [string]$Path = 'configuration'
    )

    if ($SqlCredential -is [pscredential]) {
        return @{
            UserName = $SqlCredential.UserName
            Password = $SqlCredential.GetNetworkCredential().Password
        }
    }

    if ($SqlCredential -is [System.Collections.IDictionary]) {
        $missing = @('UserName','Password' | Where-Object { $SqlCredential.Keys -notcontains $_ })
        if ($missing.Count -gt 0) {
            throw "Config file '$Path' setting SqlCredential must define: $($missing -join ', ') when UseIntegratedSecurity = `$false."
        }

        if ([string]::IsNullOrWhiteSpace([string]$SqlCredential['UserName']) -or [string]::IsNullOrWhiteSpace([string]$SqlCredential['Password'])) {
            throw "Config file '$Path' setting SqlCredential must contain non-empty UserName and Password values when UseIntegratedSecurity = `$false."
        }

        return @{
            UserName = [string]$SqlCredential['UserName']
            Password = [string]$SqlCredential['Password']
        }
    }

    throw "Config file '$Path' setting SqlCredential must be a PSCredential or a hashtable with UserName and Password when UseIntegratedSecurity = `$false."
}

function ConvertTo-ToastPositiveInt {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$SettingName,
        [string]$Path = 'configuration'
    )

    $isIntegral = $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]

    if (-not $isIntegral) {
        throw "Config file '$Path' setting $SettingName must be a positive integer."
    }

    if ($Value -is [uint64]) {
        if ($Value -gt [uint64][int]::MaxValue) {
            throw "Config file '$Path' setting $SettingName must be a positive integer."
        }

        $normalizedValue = [int]$Value
    } else {
        $wideValue = [long]$Value
        if ($wideValue -gt [int]::MaxValue) {
            throw "Config file '$Path' setting $SettingName must be a positive integer."
        }

        $normalizedValue = [int]$wideValue
    }

    if ($normalizedValue -le 0) {
        throw "Config file '$Path' setting $SettingName must be a positive integer."
    }

    return $normalizedValue
}

function Get-ToastNormalizedImageContentType {
    param(
        [AllowNull()][string]$ContentType
    )

    if ([string]::IsNullOrWhiteSpace($ContentType)) {
        return $null
    }

    $normalizedContentType = $ContentType.Trim().ToLowerInvariant()
    if ($normalizedContentType -eq 'image/jpg') {
        return 'image/jpeg'
    }

    if ($script:ToastSupportedImageContentTypes.ContainsKey($normalizedContentType)) {
        return $normalizedContentType
    }

    return $null
}

function Resolve-ToastImageContentTypeFromPath {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $extension = [System.IO.Path]::GetExtension($Path)
    switch ($extension.ToLowerInvariant()) {
        '.png' { return 'image/png' }
        '.jpg' { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.gif' { return 'image/gif' }
        '.bmp' { return 'image/bmp' }
        default { throw "Unsupported image file extension '$extension'. Supported extensions are .png, .jpg, .jpeg, .gif, and .bmp." }
    }
}

function Test-ToastImageSize {
    param(
        [Parameter(Mandatory)][byte[]]$ImageBytes,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ($ImageBytes.Length -eq 0) {
        throw "$ParameterName must not be empty."
    }

    if ($ImageBytes.Length -gt $script:ToastMaxImageBytes) {
        throw "$ParameterName exceeds the maximum supported image size of $($script:ToastMaxImageBytes) bytes."
    }
}

function Clear-StaleToastTemporaryFiles {
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) $script:ToastTemporaryDirectoryName
    if (-not (Test-Path -LiteralPath $temporaryDirectory)) {
        return
    }

    $cutoffUtc = [datetime]::UtcNow.AddMinutes(-$script:ToastTemporaryFileRetentionMinutes)
    $supportedExtensions = @($script:ToastSupportedImageContentTypes.Values)

    $staleFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($filePath in [System.IO.Directory]::EnumerateFiles($temporaryDirectory, "$($script:ToastTemporaryFilePrefix)*")) {
        try {
            $fileInfo = [System.IO.FileInfo]::new($filePath)
            $processIdSegment = $fileInfo.BaseName.Substring($script:ToastTemporaryFilePrefix.Length).Split('-')[0]
            $ownerProcessId = 0
            $hasOwnerProcessId = [int]::TryParse($processIdSegment, [ref]$ownerProcessId)
            $ownerProcessIsRunning = $hasOwnerProcessId -and $null -ne (Get-Process -Id $ownerProcessId -ErrorAction SilentlyContinue)

            if (($supportedExtensions -contains $fileInfo.Extension.ToLowerInvariant()) -and $fileInfo.LastWriteTimeUtc -lt $cutoffUtc -and -not $ownerProcessIsRunning) {
                $staleFiles.Add($filePath)
            }
        } catch {
            continue
        }
    }

    foreach ($staleFilePath in $staleFiles) {
        try {
            Remove-Item -LiteralPath $staleFilePath -Force -ErrorAction Stop
        } catch {
            continue
        }
    }
}

function Get-ToastTemporaryImageDirectory {
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) $script:ToastTemporaryDirectoryName
    if (-not (Test-Path -LiteralPath $temporaryDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    }

    return $temporaryDirectory
}

function Remove-ToastTemporaryFiles {
    param(
        [string[]]$Paths = @()
    )

    foreach ($temporaryFile in $Paths) {
        if ([string]::IsNullOrWhiteSpace($temporaryFile)) {
            continue
        }

        try {
            if (Test-Path -LiteralPath $temporaryFile) {
                Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning "Failed to remove temporary toast image '$temporaryFile': $($_.Exception.Message)"
        }
    }
}

function Resolve-ToastImageInput {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [byte[]]$ImageBytes,
        [string]$ContentType,
        [Parameter(Mandatory)][string]$ParameterName
    )

    $hasFilePath = -not [string]::IsNullOrWhiteSpace($FilePath)
    $hasImageBytes = $PSBoundParameters.ContainsKey('ImageBytes') -and $null -ne $ImageBytes

    if ($hasFilePath -and $hasImageBytes) {
        throw "Specify either $ParameterName file path or direct bytes, not both."
    }

    if (-not $hasFilePath -and -not $hasImageBytes) {
        if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
            throw "$ParameterName content type requires image bytes or a file path."
        }

        return [pscustomobject]@{
            ImageBytes = $null
            ContentType = $null
        }
    }

    if ($hasImageBytes) {
        $normalizedContentType = Get-ToastNormalizedImageContentType -ContentType $ContentType
        if ($null -eq $normalizedContentType) {
            throw "$ParameterName content type is required and must be one of: $($script:ToastSupportedImageContentTypes.Keys -join ', ')."
        }

        Test-ToastImageSize -ImageBytes $ImageBytes -ParameterName $ParameterName
        return [pscustomobject]@{
            ImageBytes = $ImageBytes
            ContentType = $normalizedContentType
        }
    }

    $resolvedPath = (Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).Path
    $normalizedContentType = Get-ToastNormalizedImageContentType -ContentType $ContentType
    $inferredContentType = Resolve-ToastImageContentTypeFromPath -Path $resolvedPath
    if ($null -ne $normalizedContentType -and $normalizedContentType -ne $inferredContentType) {
        throw "$ParameterName content type '$normalizedContentType' does not match file extension '$([System.IO.Path]::GetExtension($resolvedPath))'."
    }

    $resolvedImageBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    Test-ToastImageSize -ImageBytes $resolvedImageBytes -ParameterName $ParameterName
    return [pscustomobject]@{
        ImageBytes = $resolvedImageBytes
        ContentType = if ($null -ne $normalizedContentType) { $normalizedContentType } else { $inferredContentType }
    }
}

function Resolve-ToastRepeatSettings {
    [CmdletBinding()]
    param(
        [Nullable[int]]$RepeatIntervalSeconds,
        [Nullable[int]]$RepeatIntervalMinutes,
        [Nullable[int]]$RepeatCount
    )

    $hasSeconds = $PSBoundParameters.ContainsKey('RepeatIntervalSeconds') -and $null -ne $RepeatIntervalSeconds
    $hasMinutes = $PSBoundParameters.ContainsKey('RepeatIntervalMinutes') -and $null -ne $RepeatIntervalMinutes
    $hasCount = $PSBoundParameters.ContainsKey('RepeatCount') -and $null -ne $RepeatCount

    if ($hasSeconds -and $hasMinutes) {
        throw 'Specify either RepeatIntervalSeconds or RepeatIntervalMinutes, not both.'
    }

    if (($hasSeconds -or $hasMinutes) -and -not $hasCount) {
        throw 'RepeatCount is required when a repeat interval is specified.'
    }

    if ($hasCount -and -not ($hasSeconds -or $hasMinutes)) {
        throw 'RepeatIntervalSeconds or RepeatIntervalMinutes is required when RepeatCount is specified.'
    }

    if (-not $hasCount) {
        return @{
            RepeatIntervalSeconds = $null
            RepeatCount = $null
        }
    }

    $normalizedRepeatCount = ConvertTo-ToastPositiveInt -Value $RepeatCount -SettingName 'RepeatCount'
    if ($normalizedRepeatCount -lt 2) {
        throw 'RepeatCount must be 2 or greater because it includes the first display. Omit repeat settings for a one-time toast.'
    }

    if ($hasSeconds) {
        $normalizedRepeatIntervalSeconds = ConvertTo-ToastPositiveInt -Value $RepeatIntervalSeconds -SettingName 'RepeatIntervalSeconds'
    } else {
        $normalizedRepeatIntervalMinutes = ConvertTo-ToastPositiveInt -Value $RepeatIntervalMinutes -SettingName 'RepeatIntervalMinutes'
        if ($normalizedRepeatIntervalMinutes -gt [math]::Floor([int]::MaxValue / 60)) {
            throw 'RepeatIntervalMinutes is too large.'
        }

        $normalizedRepeatIntervalSeconds = $normalizedRepeatIntervalMinutes * 60
    }

    return @{
        RepeatIntervalSeconds = $normalizedRepeatIntervalSeconds
        RepeatCount = $normalizedRepeatCount
    }
}

function Resolve-ToastButtonSettings {
    [CmdletBinding()]
    param(
        [string]$ButtonText,
        [string]$ButtonArguments,
        [ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType
    )

    $normalizedButtonText = if ([string]::IsNullOrWhiteSpace($ButtonText)) { $null } else { $ButtonText.Trim() }
    $normalizedButtonArguments = if ([string]::IsNullOrWhiteSpace($ButtonArguments)) { $null } else { $ButtonArguments.Trim() }

    if (($null -eq $normalizedButtonText) -and ($null -ne $normalizedButtonArguments)) {
        throw 'ButtonText must be specified when ButtonArguments is provided.'
    }

    if (($null -eq $normalizedButtonText) -and [string]::IsNullOrWhiteSpace($ButtonActivationType)) {
        return @{
            ButtonText = $null
            ButtonArguments = $null
            ButtonActivationType = $null
        }
    }

    if ($null -eq $normalizedButtonText) {
        throw 'ButtonText is required when ButtonActivationType is specified.'
    }

    $normalizedButtonActivationType = if ([string]::IsNullOrWhiteSpace($ButtonActivationType)) { 'Protocol' } else { $ButtonActivationType }
    if ($normalizedButtonActivationType -eq 'Protocol') {
        if ($null -eq $normalizedButtonArguments) {
            throw 'ButtonArguments is required when ButtonActivationType is Protocol.'
        }

        $buttonUri = $null
        if (
            -not [System.Uri]::TryCreate($normalizedButtonArguments, [System.UriKind]::Absolute, [ref]$buttonUri) -or
            [string]::IsNullOrWhiteSpace($buttonUri.Scheme) -or
            ($normalizedButtonArguments -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:')
        ) {
            throw 'ButtonArguments must be a valid absolute URI when ButtonActivationType is Protocol.'
        }
    } elseif ($null -eq $normalizedButtonArguments) {
        # Dismiss buttons can omit arguments.
    }

    return @{
        ButtonText = $normalizedButtonText
        ButtonArguments = $normalizedButtonArguments
        ButtonActivationType = $normalizedButtonActivationType
    }
}

function Resolve-ToastQueueResult {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result
    )

    if ($null -eq $Result) {
        throw 'Queue toast message SQL command returned no result set.'
    }

    if ($Result -is [System.Data.DataTable]) {
        if ($Result.Rows.Count -eq 0) {
            throw 'Queue toast message SQL command returned no rows.'
        }

        if (-not $Result.Columns.Contains('MessageId')) {
            throw 'Queue toast message SQL result must include a MessageId column.'
        }

        $messageId = $Result.Rows[0]['MessageId']
        if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
            throw 'Queue toast message SQL result contained a null MessageId value.'
        }

        return [pscustomobject]@{
            MessageId = [long]$messageId
        }
    }

    if ($Result -is [System.Data.DataRow]) {
        if (-not $Result.Table.Columns.Contains('MessageId')) {
            throw 'Queue toast message SQL result must include a MessageId column.'
        }

        $messageId = $Result['MessageId']
        if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
            throw 'Queue toast message SQL result contained a null MessageId value.'
        }

        return [pscustomobject]@{
            MessageId = [long]$messageId
        }
    }

    $messageIdProperty = $Result.PSObject.Properties['MessageId']
    if ($null -eq $messageIdProperty) {
        throw 'Queue toast message SQL result must expose a MessageId value.'
    }

    $messageId = $messageIdProperty.Value
    if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
        throw 'Queue toast message SQL result contained a null MessageId value.'
    }

    return [pscustomobject]@{
        MessageId = [long]$messageId
    }
}

function Resolve-ToastScenario {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Scenario
    )

    $normalizedScenario = if ([string]::IsNullOrWhiteSpace($Scenario)) { 'Default' } else { $Scenario.Trim() }
    $resolvedScenario = $script:ToastSupportedScenarios | Where-Object { $_.Equals($normalizedScenario, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($null -eq $resolvedScenario) {
        throw "Scenario must be one of: $($script:ToastSupportedScenarios -join ', ')."
    }

    return $resolvedScenario
}

function Resolve-ToastDisplayMode {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$DisplayMode
    )

    $normalizedDisplayMode = if ([string]::IsNullOrWhiteSpace($DisplayMode)) { 'BurntToast' } else { $DisplayMode.Trim() }
    foreach ($supportedDisplayMode in $script:ToastSupportedDisplayModes) {
        if ($supportedDisplayMode.Equals($normalizedDisplayMode, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $supportedDisplayMode
        }
    }

    throw "DisplayMode must be one of: $($script:ToastSupportedDisplayModes -join ', ')."
}

function Set-ToastClientDependencyOptions {
    [CmdletBinding()]
    param(
        [string]$InternalPowerShellRepository,
        [string]$AppDeployToolkitModulePath
    )

    $script:ToastDependencyOptions = @{
        InternalPowerShellRepository = if ([string]::IsNullOrWhiteSpace($InternalPowerShellRepository)) { $null } else { $InternalPowerShellRepository.Trim() }
        AppDeployToolkitModulePath = if ([string]::IsNullOrWhiteSpace($AppDeployToolkitModulePath)) { $null } else { $AppDeployToolkitModulePath.Trim() }
    }
}

function Resolve-ToastDependencyImportPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DependencyPath,
        [Parameter(Mandatory)][string[]]$CandidateLeafNames
    )

    if (-not (Test-Path -LiteralPath $DependencyPath)) {
        throw "Configured dependency path '$DependencyPath' was not found."
    }

    $resolvedDependencyPath = (Resolve-Path -LiteralPath $DependencyPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
    $dependencyItem = Get-Item -LiteralPath $resolvedDependencyPath -ErrorAction Stop
    if (-not $dependencyItem.PSIsContainer) {
        return $resolvedDependencyPath
    }

    foreach ($candidateLeafName in $CandidateLeafNames) {
        $topLevelCandidatePath = Join-Path $resolvedDependencyPath $candidateLeafName
        if (Test-Path -LiteralPath $topLevelCandidatePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $topLevelCandidatePath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
        }
    }

    $candidatePriority = @{}
    for ($index = 0; $index -lt $CandidateLeafNames.Count; $index++) {
        $candidatePriority[$CandidateLeafNames[$index]] = $index
    }

    $candidate = Get-ChildItem -LiteralPath $resolvedDependencyPath -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
        Where-Object { $CandidateLeafNames -contains $_.Name } |
        Sort-Object @{ Expression = { ($_.FullName -split '[\\/]').Count } }, @{ Expression = { $candidatePriority[$_.Name] } }, FullName |
        Select-Object -First 1
    if ($null -ne $candidate) {
        return $candidate.FullName
    }

    throw "Configured dependency path '$resolvedDependencyPath' does not contain any of: $($CandidateLeafNames -join ', ')."
}

function Get-ToastAppDeployToolkitPromptCommand {
    [CmdletBinding()]
    param()

    foreach ($commandName in @('Show-ADTInstallationPrompt','Show-InstallationPrompt')) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command
        }
    }

    return $null
}

function Ensure-ToastNotificationDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayMode
    )

    $resolvedDisplayMode = Resolve-ToastDisplayMode -DisplayMode $DisplayMode
    switch ($resolvedDisplayMode) {
        'BurntToast' {
            if ($null -ne (Get-Command -Name 'New-BurntToastNotification' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                return
            }

            if ($script:ToastDependencyOptions.InternalPowerShellRepository) {
                Install-Module BurntToast -Repository $script:ToastDependencyOptions.InternalPowerShellRepository -Scope CurrentUser -Force
            } else {
                Write-Warning 'BurntToast is not installed. Install it from your approved repository.'
            }

            Import-Module BurntToast -ErrorAction Stop
            return
        }
        'AppDeployToolkit' {
            if ($null -ne (Get-ToastAppDeployToolkitPromptCommand)) {
                return
            }

            if (-not $script:ToastDependencyOptions.AppDeployToolkitModulePath) {
                throw "DisplayMode 'AppDeployToolkit' requires a locally packaged PSAppDeployToolkit copy. Configure AppDeployToolkitModulePath to a version-pinned manifest, bootstrap script, or containing folder before starting the client."
            }

            $importPath = Resolve-ToastDependencyImportPath `
                -DependencyPath $script:ToastDependencyOptions.AppDeployToolkitModulePath `
                -CandidateLeafNames @('PSAppDeployToolkit.psd1','PSAppDeployToolkit.psm1','AppDeployToolkitMain.psm1')
            Import-Module -Name $importPath -ErrorAction Stop

            if ($null -eq (Get-ToastAppDeployToolkitPromptCommand)) {
                throw "AppDeployToolkit dependency '$importPath' did not expose Show-ADTInstallationPrompt or Show-InstallationPrompt."
            }
        }
    }
}

function Resolve-ToastAppDeployToolkitButtonSettings {
    [CmdletBinding()]
    param(
        [string]$ButtonText,
        [string]$ButtonArguments,
        [string]$ButtonActivationType
    )

    $buttonSettings = Resolve-ToastWpfButtonSettings `
        -ButtonText $ButtonText `
        -ButtonArguments $ButtonArguments `
        -ButtonActivationType $ButtonActivationType
    $protocolUri = $null

    if ($buttonSettings.ButtonActivationType -eq 'Protocol') {
        $protocolUri = Resolve-ToastWpfProtocolUri -ButtonArguments $buttonSettings.ButtonArguments
        if ($null -eq $protocolUri) {
            throw 'AppDeployToolkit protocol buttons support only absolute http, https, or mailto URIs.'
        }
    }

    return [pscustomobject]@{
        ButtonText = $buttonSettings.ButtonText
        ButtonArguments = $buttonSettings.ButtonArguments
        ButtonActivationType = $buttonSettings.ButtonActivationType
        ProtocolUri = $protocolUri
    }
}

function Resolve-ToastAppDeployToolkitPromptSelection {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result,
        [string]$ActionButtonText,
        [string]$AcknowledgeButtonText = 'Acknowledge'
    )

    if ($null -eq $Result) {
        return 'Acknowledge'
    }

    $valuesToInspect = [System.Collections.Generic.List[string]]::new()
    if ($Result -is [string]) {
        $valuesToInspect.Add($Result)
    }

    foreach ($propertyName in @('Button','SelectedButton','Selection','Result','Value')) {
        $property = $Result.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $valuesToInspect.Add([string]$property.Value)
        }
    }

    if ($Result -is [int] -or $Result -is [long] -or $Result -is [short] -or $Result -is [byte]) {
        $numericResult = [int]$Result
        if (-not [string]::IsNullOrWhiteSpace($ActionButtonText) -and $numericResult -eq 0) {
            return 'Action'
        }

        if ($numericResult -eq 1) {
            return 'Acknowledge'
        }
    }

    foreach ($value in $valuesToInspect) {
        $normalizedValue = if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value.Trim() }
        if ($null -eq $normalizedValue) {
            continue
        }

        if (
            -not [string]::IsNullOrWhiteSpace($ActionButtonText) -and (
                $normalizedValue.Equals($ActionButtonText, [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('Left', [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('ButtonLeft', [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('Action', [System.StringComparison]::OrdinalIgnoreCase)
            )
        ) {
            return 'Action'
        }

        if (
            $normalizedValue.Equals($AcknowledgeButtonText, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('Right', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('ButtonRight', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('OK', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('Acknowledge', [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            return 'Acknowledge'
        }
    }

    return 'Acknowledge'
}

function Show-ToastAppDeployToolkitPrompt {
    [CmdletBinding()]
    param(
        [AllowNull()][long]$MessageId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$ButtonText,
        [string]$ButtonArguments,
        [string]$ButtonActivationType
    )

    Ensure-ToastNotificationDependencies -DisplayMode 'AppDeployToolkit'
    $promptCommand = Get-ToastAppDeployToolkitPromptCommand
    if ($null -eq $promptCommand) {
        throw "AppDeployToolkit display mode could not find Show-ADTInstallationPrompt or Show-InstallationPrompt after dependency loading."
    }

    $buttonSettings = Resolve-ToastAppDeployToolkitButtonSettings `
        -ButtonText $ButtonText `
        -ButtonArguments $ButtonArguments `
        -ButtonActivationType $ButtonActivationType

    $messageText = if ([string]::IsNullOrWhiteSpace($Title)) {
        [string]$Body
    } elseif ([string]::IsNullOrWhiteSpace($Body)) {
        [string]$Title
    } else {
        "$Title`r`n`r`n$Body"
    }

    $acknowledgeButtonText = 'Acknowledge'
    $promptParameters = @{
        Message = $messageText
        ButtonRightText = $acknowledgeButtonText
    }

    if ($promptCommand.Parameters.Keys -contains 'Title' -and -not [string]::IsNullOrWhiteSpace($Title)) {
        $promptParameters['Title'] = [string]$Title
        if (-not [string]::IsNullOrWhiteSpace($Body)) {
            $promptParameters['Message'] = [string]$Body
        }
    }

    foreach ($iconMapping in @(
        @{ ParameterName = 'Icon'; Value = 'Information' },
        @{ ParameterName = 'IconType'; Value = 'Information' },
        @{ ParameterName = 'MessageBoxIcon'; Value = 64 }
    )) {
        if ($promptCommand.Parameters.Keys -contains $iconMapping.ParameterName) {
            $promptParameters[$iconMapping.ParameterName] = $iconMapping.Value
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($buttonSettings.ButtonText)) {
        $promptParameters['ButtonLeftText'] = [string]$buttonSettings.ButtonText
    }

    try {
        $result = & $promptCommand @promptParameters
    } catch {
        throw [System.Exception]::new("AppDeployToolkit prompt execution failed for MessageId ${MessageId}.", $_.Exception)
    }
    $selection = Resolve-ToastAppDeployToolkitPromptSelection `
        -Result $result `
        -ActionButtonText $buttonSettings.ButtonText `
        -AcknowledgeButtonText $acknowledgeButtonText

    if ($selection -eq 'Action' -and $buttonSettings.ButtonActivationType -eq 'Protocol') {
        $protocolActionError = Invoke-ToastProtocolAction -ButtonArguments $buttonSettings.ProtocolUri.AbsoluteUri
        if (-not [string]::IsNullOrWhiteSpace($protocolActionError)) {
            throw "Failed to open AppDeployToolkit action '$($buttonSettings.ProtocolUri.AbsoluteUri)' for MessageId ${MessageId}: $protocolActionError"
        }
    }

    $resultType = switch ($selection) {
        'Action' {
            if ($buttonSettings.ButtonActivationType -eq 'Dismiss') { 'Dismiss' } else { 'Action' }
            break
        }
        default { 'Acknowledge' }
    }

    return [pscustomobject]@{
        Selection = $selection
        ResultType = $resultType
        ButtonActivationType = $buttonSettings.ButtonActivationType
    }
}

function Get-ToastWpfBitmapImage {
    [CmdletBinding()]
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$ImageRole,
        [AllowNull()][long]$MessageId
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $bitmapImage = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmapImage.BeginInit()
        $bitmapImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmapImage.UriSource = [System.Uri]::new($resolvedPath, [System.UriKind]::Absolute)
        $bitmapImage.EndInit()
        $bitmapImage.Freeze()
        return $bitmapImage
    } catch {
        Write-Warning "Failed to load WPF $ImageRole image '$Path' for MessageId $($MessageId): $($_.Exception.Message)"
        return $null
    }
}

function Resolve-ToastWpfButtonSettings {
    [CmdletBinding()]
    param(
        [string]$ButtonText,
        [string]$ButtonArguments,
        [string]$ButtonActivationType
    )

    $normalizedButtonText = if ([string]::IsNullOrWhiteSpace([string]$ButtonText)) { $null } else { [string]$ButtonText }
    if ($null -eq $normalizedButtonText) {
        return @{
            ButtonText = $null
            ButtonArguments = $null
            ButtonActivationType = $null
        }
    }

    $normalizedButtonArguments = if ([string]::IsNullOrWhiteSpace([string]$ButtonArguments)) { $null } else { [string]$ButtonArguments }
    $normalizedButtonActivationType = if ([string]::IsNullOrWhiteSpace([string]$ButtonActivationType)) { 'Protocol' } else { [string]$ButtonActivationType }

    if ($normalizedButtonActivationType -eq 'Dismiss' -or $null -eq $normalizedButtonArguments) {
        return @{
            ButtonText = $normalizedButtonText
            ButtonArguments = $null
            ButtonActivationType = 'Dismiss'
        }
    }

    return @{
        ButtonText = $normalizedButtonText
        ButtonArguments = $normalizedButtonArguments
        ButtonActivationType = 'Protocol'
    }
}

function Resolve-ToastWpfProtocolUri {
    [CmdletBinding()]
    param(
        [string]$ButtonArguments
    )

    if ([string]::IsNullOrWhiteSpace([string]$ButtonArguments)) {
        return $null
    }

    $protocolUri = $null
    if (-not [System.Uri]::TryCreate([string]$ButtonArguments, [System.UriKind]::Absolute, [ref]$protocolUri)) {
        return $null
    }

    if ($script:ToastSupportedWpfProtocolSchemes -notcontains $protocolUri.Scheme.ToLowerInvariant()) {
        return $null
    }

    return $protocolUri
}

function Invoke-ToastProtocolAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ButtonArguments
    )

    try {
        Start-Process -FilePath $ButtonArguments -ErrorAction Stop | Out-Null
        return $null
    } catch {
        return $_.Exception.Message
    }
}

function Invoke-ToastWpfProtocolAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ButtonArguments
    )

    return Invoke-ToastProtocolAction -ButtonArguments $ButtonArguments
}

function Resolve-ToastWpfCloseBehavior {
    [CmdletBinding()]
    param(
        [bool]$Acknowledged,
        [bool]$SessionEnding
    )

    if ($Acknowledged -or $SessionEnding) {
        return [pscustomobject]@{
            AllowClose = $true
        }
    }

    return [pscustomobject]@{
        AllowClose = $false
    }
}

function Show-ToastAcknowledgementWindow {
    [CmdletBinding()]
    param(
        [AllowNull()][long]$MessageId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$AppLogoPath,
        [string]$HeroImagePath,
        [string]$ButtonText,
        [string]$ButtonArguments,
        [ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType = 'Protocol'
    )

    $currentApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($currentApartmentState -ne [System.Threading.ApartmentState]::STA) {
        throw "WPF acknowledgement mode requires an STA thread. Start the client in an STA PowerShell host or use an STA runspace. Current apartment state: $currentApartmentState."
    }

    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        throw "WPF acknowledgement mode requires Windows Presentation Foundation assemblies. MessageId $MessageId failed. Details: $($_.Exception.Message)"
    }

    $windowState = [hashtable]::Synchronized(@{
        Acknowledged = $false
        SessionEnding = $false
    })

    $window = New-Object System.Windows.Window
    $window.Title = if ([string]::IsNullOrWhiteSpace($Title)) { 'Notification' } else { $Title }
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.AllowsTransparency = $false
    $window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF202020')
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $window.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $window.ShowInTaskbar = $true
    $window.ShowActivated = $true
    $window.Topmost = $true

    $outerBorder = New-Object System.Windows.Controls.Border
    $outerBorder.CornerRadius = [System.Windows.CornerRadius]::new(18)
    $outerBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $outerBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF404040')
    $outerBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF202020')
    $outerBorder.Padding = [System.Windows.Thickness]::new(18)
    $outerBorder.MaxWidth = 460

    $rootPanel = New-Object System.Windows.Controls.StackPanel
    $rootPanel.Orientation = [System.Windows.Controls.Orientation]::Vertical

    $heroImage = Get-ToastWpfBitmapImage -Path $HeroImagePath -ImageRole 'hero' -MessageId $MessageId
    if ($null -ne $heroImage) {
        $heroImageControl = New-Object System.Windows.Controls.Image
        $heroImageControl.Source = $heroImage
        $heroImageControl.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $heroImageControl.Height = 140
        $heroImageControl.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
        $heroImageControl.SnapsToDevicePixels = $true
        [void]$rootPanel.Children.Add($heroImageControl)
    }

    $contentGrid = New-Object System.Windows.Controls.Grid
    $contentGrid.Margin = [System.Windows.Thickness]::new(0)

    $appLogoImage = Get-ToastWpfBitmapImage -Path $AppLogoPath -ImageRole 'app logo' -MessageId $MessageId
    if ($null -ne $appLogoImage) {
        [void]$contentGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
        [void]$contentGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

        $logoImageControl = New-Object System.Windows.Controls.Image
        $logoImageControl.Source = $appLogoImage
        $logoImageControl.Width = 48
        $logoImageControl.Height = 48
        $logoImageControl.Margin = [System.Windows.Thickness]::new(0, 2, 14, 0)
        $logoImageControl.Stretch = [System.Windows.Media.Stretch]::Uniform
        [System.Windows.Controls.Grid]::SetColumn($logoImageControl, 0)
        [void]$contentGrid.Children.Add($logoImageControl)
    } else {
        [void]$contentGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    }

    $textPanel = New-Object System.Windows.Controls.StackPanel
    $textPanel.Orientation = [System.Windows.Controls.Orientation]::Vertical

    $titleRow = New-Object System.Windows.Controls.Grid
    [void]$titleRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    [void]$titleRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $titleRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = [string]$Title
    $titleBlock.FontSize = 18
    $titleBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleBlock.Foreground = [System.Windows.Media.Brushes]::White
    $titleBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [System.Windows.Controls.Grid]::SetColumn($titleBlock, 0)
    [void]$titleRow.Children.Add($titleBlock)

    $closeButton = New-Object System.Windows.Controls.Button
    $closeButton.Content = 'Close'
    $closeButton.MinWidth = 78
    $closeButton.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $closeButton.Padding = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $closeButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF2F2F2F')
    $closeButton.Foreground = [System.Windows.Media.Brushes]::White
    $closeButton.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF5A5A5A')
    $closeButton.Add_Click({
        $windowState['Acknowledged'] = $true
        $window.Close()
    })
    [System.Windows.Controls.Grid]::SetColumn($closeButton, 1)
    [void]$titleRow.Children.Add($closeButton)

    [void]$textPanel.Children.Add($titleRow)

    $bodyViewer = New-Object System.Windows.Controls.ScrollViewer
    $bodyViewer.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $bodyViewer.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $bodyViewer.MaxHeight = 220

    $bodyBlock = New-Object System.Windows.Controls.TextBlock
    $bodyBlock.Text = [string]$Body
    $bodyBlock.FontSize = 14
    $bodyBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF0F0F0')
    $bodyBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $bodyBlock.LineStackingStrategy = [System.Windows.LineStackingStrategy]::BlockLineHeight
    $bodyBlock.LineHeight = 20
    $bodyViewer.Content = $bodyBlock
    [void]$textPanel.Children.Add($bodyViewer)

    if ($null -ne $appLogoImage) {
        [System.Windows.Controls.Grid]::SetColumn($textPanel, 1)
    } else {
        [System.Windows.Controls.Grid]::SetColumn($textPanel, 0)
    }

    [void]$contentGrid.Children.Add($textPanel)
    [void]$rootPanel.Children.Add($contentGrid)

    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttonPanel.Margin = [System.Windows.Thickness]::new(0, 18, 0, 0)

    if (-not [string]::IsNullOrWhiteSpace([string]$ButtonText)) {
        $actionButton = New-Object System.Windows.Controls.Button
        $actionButton.Content = [string]$ButtonText
        $actionButton.MinWidth = 96
        $actionButton.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
        $actionButton.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
        $actionButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF2F2F2F')
        $actionButton.Foreground = [System.Windows.Media.Brushes]::White
        $actionButton.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF5A5A5A')

        if ($ButtonActivationType -eq 'Dismiss') {
            $actionButton.Add_Click({
                $windowState['Acknowledged'] = $true
                $window.Close()
            })
        } else {
            $protocolTarget = $ButtonArguments
            $actionButton.Add_Click({
                $protocolActionError = Invoke-ToastWpfProtocolAction -ButtonArguments $protocolTarget
                if (-not [string]::IsNullOrWhiteSpace($protocolActionError)) {
                    [void][System.Windows.MessageBox]::Show(
                        $window,
                        "Failed to open '$protocolTarget'.`n`n$protocolActionError",
                        'Notification action failed',
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Warning
                    )
                    $window.Activate() | Out-Null
                } else {
                    $windowState['Acknowledged'] = $true
                    $window.Close()
                }
            })
        }

        [void]$buttonPanel.Children.Add($actionButton)
    }

    $acknowledgeButton = New-Object System.Windows.Controls.Button
    $acknowledgeButton.Content = 'Acknowledge'
    $acknowledgeButton.MinWidth = 124
    $acknowledgeButton.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $acknowledgeButton.IsDefault = $true
    $acknowledgeButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF0078D4')
    $acknowledgeButton.Foreground = [System.Windows.Media.Brushes]::White
    $acknowledgeButton.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF0078D4')
    $acknowledgeButton.Add_Click({
        $windowState['Acknowledged'] = $true
        $window.Close()
    })
    [void]$buttonPanel.Children.Add($acknowledgeButton)

    [void]$rootPanel.Children.Add($buttonPanel)
    $outerBorder.Child = $rootPanel
    $window.Content = $outerBorder

    $window.Add_Closing({
        param($sender, $eventArgs)
        $closeBehavior = Resolve-ToastWpfCloseBehavior -Acknowledged:$windowState['Acknowledged'] -SessionEnding:$windowState['SessionEnding']
        if (-not $closeBehavior.AllowClose) {
            $eventArgs.Cancel = $true
            $sender.Activate() | Out-Null
        }
    })

    $window.Add_ContentRendered({
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $window.Left = [Math]::Max($workArea.Left + 12, $workArea.Right - $window.ActualWidth - 16)
        $window.Top = [Math]::Max($workArea.Top + 12, $workArea.Bottom - $window.ActualHeight - 16)
        $window.Activate() | Out-Null
        $acknowledgeButton.Focus() | Out-Null
    })

    $sessionEndingHandler = [Microsoft.Win32.SessionEndingEventHandler]{
        param($sender, $eventArgs)
        $windowState['SessionEnding'] = $true
    }

    $sessionEndingRegistered = $false
    try {
        [Microsoft.Win32.SystemEvents]::add_SessionEnding($sessionEndingHandler)
        $sessionEndingRegistered = $true
    } catch {
        Write-Warning "Failed to subscribe to SessionEnding for WPF acknowledgement mode. MessageId $MessageId may rely on in-window acknowledgement handling only. Details: $($_.Exception.Message)"
    }

    try {
        [void]$window.ShowDialog()
    }
    finally {
        if ($sessionEndingRegistered) {
            [Microsoft.Win32.SystemEvents]::remove_SessionEnding($sessionEndingHandler)
        }
    }
}

function ConvertTo-ToastSoundSourceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sound
    )

    $normalizedSound = $Sound.Trim()
    switch -Regex ($normalizedSound) {
        '^(?i)Default$' { return 'ms-winsoundevent:Notification.Default' }
        '^(?i)IM$' { return 'ms-winsoundevent:Notification.IM' }
        '^(?i)Mail$' { return 'ms-winsoundevent:Notification.Mail' }
        '^(?i)Reminder$' { return 'ms-winsoundevent:Notification.Reminder' }
        '^(?i)SMS$' { return 'ms-winsoundevent:Notification.SMS' }
        '^(?i)Alarm$' { return 'ms-winsoundevent:Notification.Looping.Alarm' }
        '^(?i)Call$' { return 'ms-winsoundevent:Notification.Looping.Call' }
        '^(?i)Alarm([2-9]|10)$' { return "ms-winsoundevent:Notification.Looping.Alarm$($Matches[1])" }
        '^(?i)Call([2-9]|10)$' { return "ms-winsoundevent:Notification.Looping.Call$($Matches[1])" }
    }

    return $null
}

function Get-ToastBurntToastInvocationDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ToastParameters,
        [Parameter(Mandatory)]$BurntToastCommand,
        [AllowNull()][long]$MessageId
    )

    $parametersToInvoke = @{}
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parameterName in $ToastParameters.Keys) {
        if ($BurntToastCommand.Parameters.Keys -contains $parameterName) {
            $parametersToInvoke[$parameterName] = $ToastParameters[$parameterName]
        } else {
            $warnings.Add("Installed BurntToast does not support parameter '$parameterName'. MessageId $MessageId will be shown without this option.")
        }
    }

    return [pscustomobject]@{
        Parameters = $parametersToInvoke
        Warnings = $warnings.ToArray()
    }
}

function Get-ToastNotificationParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow,
        [string[]]$SupportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent','Button'),
        [string]$DisplayMode = 'BurntToast'
    )

    $supportedParameterLookup = @{}
    foreach ($parameterName in $SupportedParameters) {
        $supportedParameterLookup[$parameterName] = $true
    }

    $resolvedDisplayMode = Resolve-ToastDisplayMode -DisplayMode $DisplayMode
    $isWpfDisplayMode = $resolvedDisplayMode -eq 'Wpf'

    $parameters = @{
        Text = @(
            [string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Title'),
            [string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Body')
        )
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $temporaryFiles = [System.Collections.Generic.List[string]]::new()
    Clear-StaleToastTemporaryFiles

    foreach ($mapping in @(
        @{ PathPropertyName = 'AppLogoPath'; BytesPropertyName = 'AppLogoBytes'; ContentTypePropertyName = 'AppLogoContentType'; ParameterName = 'AppLogo' },
        @{ PathPropertyName = 'HeroImagePath'; BytesPropertyName = 'HeroImageBytes'; ContentTypePropertyName = 'HeroImageContentType'; ParameterName = 'HeroImage' },
        @{ PropertyName = 'Sound'; ParameterName = 'Sound' }
    )) {
        if ($isWpfDisplayMode -and $mapping.ParameterName -eq 'Sound') {
            continue
        }

        $value = $null
        if ($mapping.ContainsKey('PathPropertyName')) {
            $pathValue = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName $mapping.PathPropertyName
            $imageBytes = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName $mapping.BytesPropertyName
            $imageContentType = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName $mapping.ContentTypePropertyName

            $hasBinaryImage = $imageBytes -is [byte[]]

            if ($supportedParameterLookup.ContainsKey($mapping.ParameterName)) {
                if ($hasBinaryImage) {
                    $normalizedContentType = Get-ToastNormalizedImageContentType -ContentType ([string]$imageContentType)
                    if ($null -eq $normalizedContentType) {
                        throw "Unsupported $($mapping.ParameterName) content type '$imageContentType'. Supported content types are: $($script:ToastSupportedImageContentTypes.Keys -join ', ')."
                    }

                    Test-ToastImageSize -ImageBytes $imageBytes -ParameterName $mapping.ParameterName
                    $temporaryImagePath = $null
                    try {
                        $temporaryImagePath = Join-Path (Get-ToastTemporaryImageDirectory) "$($script:ToastTemporaryFilePrefix)$PID-$([guid]::NewGuid().ToString('N'))$($script:ToastSupportedImageContentTypes[$normalizedContentType])"
                        [System.IO.File]::WriteAllBytes($temporaryImagePath, $imageBytes)
                        $temporaryFiles.Add($temporaryImagePath)
                        $value = $temporaryImagePath
                    } catch {
                        if (-not [string]::IsNullOrWhiteSpace($temporaryImagePath) -and (Test-Path -LiteralPath $temporaryImagePath)) {
                            Remove-ToastTemporaryFiles -Paths @($temporaryImagePath)
                        }

                        throw
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace([string]$pathValue)) {
                    $value = [string]$pathValue
                }
            } elseif ($hasBinaryImage -or -not [string]::IsNullOrWhiteSpace([string]$pathValue)) {
                $warnings.Add("Installed BurntToast does not support parameter '$($mapping.ParameterName)'. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without this option.")
            }
        } else {
            $value = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName $mapping.PropertyName
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            if ($supportedParameterLookup.ContainsKey($mapping.ParameterName)) {
                $parameters[$mapping.ParameterName] = [string]$value
            } else {
                $warnings.Add("Installed BurntToast does not support parameter '$($mapping.ParameterName)'. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without this option.")
            }
        }
    }

    if (-not $isWpfDisplayMode) {
        $isUrgent = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'IsUrgent'
        if ($null -ne $isUrgent -and [System.Convert]::ToBoolean($isUrgent)) {
            if ($supportedParameterLookup.ContainsKey('Urgent')) {
                $parameters['Urgent'] = $true
            } else {
                $warnings.Add("Installed BurntToast does not support parameter 'Urgent'. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without urgent styling.")
            }
        }
    }

    if (-not $isWpfDisplayMode) {
        $buttonText = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonText'
        $buttonArguments = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonArguments'
        $buttonActivationType = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonActivationType'
        if (-not [string]::IsNullOrWhiteSpace([string]$buttonText)) {
            $buttonCommand = Get-Command 'New-BTButton' -ErrorAction SilentlyContinue
            $hasButtonCommand = $null -ne $buttonCommand -and @($buttonCommand).Count -gt 0
            if ($supportedParameterLookup.ContainsKey('Button') -and $hasButtonCommand) {
                $resolvedButtonActivationType = if ([string]::IsNullOrWhiteSpace([string]$buttonActivationType)) { 'Protocol' } else { [string]$buttonActivationType }
                $newButtonParameters = @{
                    Content = [string]$buttonText
                }
                if ($resolvedButtonActivationType -eq 'Dismiss') {
                    if ($buttonCommand.Parameters.Keys -contains 'Dismiss') {
                        $newButtonParameters['Dismiss'] = $true
                        $parameters['Button'] = New-BTButton @newButtonParameters
                    } else {
                        $warnings.Add("Installed BurntToast version does not support dismiss action buttons. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without a dismiss button.")
                    }
                } else {
                    $newButtonParameters['ActivationType'] = $resolvedButtonActivationType
                    if (-not [string]::IsNullOrWhiteSpace([string]$buttonArguments)) {
                        $newButtonParameters['Arguments'] = [string]$buttonArguments
                    }

                    $parameters['Button'] = New-BTButton @newButtonParameters
                }
            } else {
                $warnings.Add("Installed BurntToast does not support button actions. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without action buttons.")
            }
        }
    }

    return [pscustomobject]@{
        Parameters = $parameters
        TemporaryFiles = $temporaryFiles.ToArray()
        Warnings = $warnings.ToArray()
        DisplayMode = $resolvedDisplayMode
    }
}

function Invoke-ToastNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow,
        [string[]]$SupportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent','Button')
    )

    $displayModeValue = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'DisplayMode'
    $resolvedDisplayMode = Resolve-ToastDisplayMode -DisplayMode $displayModeValue

    if ($resolvedDisplayMode -eq 'AppDeployToolkit') {
        Show-ToastAppDeployToolkitPrompt `
            -MessageId (Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') `
            -Title ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Title')) `
            -Body ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Body')) `
            -ButtonText ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonText')) `
            -ButtonArguments ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonArguments')) `
            -ButtonActivationType ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonActivationType')) | Out-Null

        return
    }

    if ($resolvedDisplayMode -eq 'Wpf') {
        $title = [string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Title')
        $body = [string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Body')
        $appLogoPath = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'AppLogoPath'
        $heroImagePath = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'HeroImagePath'
        $buttonText = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonText'
        $buttonArguments = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonArguments'
        $buttonActivationType = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonActivationType'

        $wpfButtonSettings = Resolve-ToastWpfButtonSettings `
            -ButtonText $buttonText `
            -ButtonArguments $buttonArguments `
            -ButtonActivationType $buttonActivationType

        Show-ToastAcknowledgementWindow `
            -MessageId (Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') `
            -Title $title `
            -Body $body `
            -AppLogoPath ([string]$appLogoPath) `
            -HeroImagePath ([string]$heroImagePath) `
            -ButtonText $wpfButtonSettings.ButtonText `
            -ButtonArguments $wpfButtonSettings.ButtonArguments `
            -ButtonActivationType $wpfButtonSettings.ButtonActivationType

        return
    }

    $toastDetails = Get-ToastNotificationParameters -ToastRow $ToastRow -SupportedParameters $SupportedParameters -DisplayMode $resolvedDisplayMode
    foreach ($warning in $toastDetails.Warnings) {
        Write-Warning $warning
    }

    Ensure-ToastNotificationDependencies -DisplayMode $resolvedDisplayMode
    $toastParameters = $toastDetails.Parameters
    try {
        New-BurntToastNotification @toastParameters
    }
    finally {
        Remove-ToastTemporaryFiles -Paths $toastDetails.TemporaryFiles
    }
}

function Get-ToastNotificationSupportedParameters {
    [CmdletBinding()]
    param(
        [string]$CommandName = 'New-BurntToastNotification'
    )

    $command = Get-Command $CommandName -ErrorAction Stop
    $supportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent' | Where-Object { $command.Parameters.Keys -contains $_ })
    $buttonCommand = Get-Command 'New-BTButton' -ErrorAction SilentlyContinue
    $hasButtonCommand = $null -ne $buttonCommand -and @($buttonCommand).Count -gt 0
    if (($command.Parameters.Keys -contains 'Button') -and $hasButtonCommand) {
        $supportedParameters += 'Button'
    }

    return $supportedParameters
}

function Get-ToastSqlCredential {
    param([hashtable]$Config)

    if ($Config['UseIntegratedSecurity']) {
        return $null
    }

    if (-not $Config.ContainsKey('SqlCredential') -or $null -eq $Config['SqlCredential']) {
        throw "Config setting SqlCredential is required when UseIntegratedSecurity = `$false."
    }

    $credential = Get-ToastSqlCredentialValues -SqlCredential $Config['SqlCredential']
    $securePassword = ConvertTo-SecureString -String $credential.Password -AsPlainText -Force
    $securePassword.MakeReadOnly()
    return [System.Data.SqlClient.SqlCredential]::new($credential.UserName, $securePassword)
}

function Import-ToastConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$RequiredProperties = @(),
        [string[]]$NullableProperties = @(),
        [string[]]$NonEmptyProperties = @(),
        [switch]$ResolveClientName
    )

    try {
        $config = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    } catch {
        throw "Failed to load config file '$Path': $($_.Exception.Message) PowerShell data files (.psd1) must contain only static values supported by Import-PowerShellDataFile. Replace dynamic expressions with static values."
    }

    if ($config -isnot [System.Collections.IDictionary]) {
        throw "Config file '$Path' must contain a top-level hashtable/dictionary."
    }

    if ($config -isnot [hashtable]) {
        $normalizedConfig = @{}
        foreach ($key in $config.Keys) {
            $normalizedConfig[$key] = $config[$key]
        }

        $config = $normalizedConfig
    }

    $missing = @($RequiredProperties | Where-Object { -not $config.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Config file '$Path' is missing required setting(s): $($missing -join ', '). Copy config/config.example.psd1 and define each setting explicitly."
    }

    $emptyRequired = @(
        $RequiredProperties |
            Where-Object { $_ -notin $NullableProperties } |
            Where-Object {
                $value = $config[$_]
                $null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))
            }
    )
    if ($emptyRequired.Count -gt 0) {
        throw "Config file '$Path' has empty required setting(s): $($emptyRequired -join ', '). Set each required value explicitly or copy it from config/config.example.psd1."
    }

    $emptyCollections = @(
        $NonEmptyProperties |
            Where-Object {
                $value = $config[$_]
                $value -is [System.Array] -and $value.Count -eq 0
            }
    )
    if ($emptyCollections.Count -gt 0) {
        throw "Config file '$Path' must define at least one value for: $($emptyCollections -join ', ')."
    }

    foreach ($booleanSetting in @('UseIntegratedSecurity','Encrypt','TrustServerCertificate')) {
        if ($config.ContainsKey($booleanSetting) -and $config[$booleanSetting] -isnot [bool]) {
            throw "Config file '$Path' setting $booleanSetting must be `$true or `$false."
        }
    }

    foreach ($positiveIntegerSetting in @('ConnectTimeoutSeconds','CommandTimeoutSeconds')) {
        if ($config.ContainsKey($positiveIntegerSetting)) {
            $config[$positiveIntegerSetting] = ConvertTo-ToastPositiveInt -Value $config[$positiveIntegerSetting] -SettingName $positiveIntegerSetting -Path $Path
        }
    }

    if ($config.ContainsKey('UseIntegratedSecurity') -and -not $config['UseIntegratedSecurity']) {
        if (-not $config.ContainsKey('SqlCredential') -or $null -eq $config['SqlCredential']) {
            throw "Config file '$Path' sets UseIntegratedSecurity = `$false, so SqlCredential must be provided as a PSCredential or as a static hashtable with UserName and Password."
        }

        [void](Get-ToastSqlCredentialValues -SqlCredential $config['SqlCredential'] -Path $Path)
    }

    if ($ResolveClientName) {
        if (-not $config.ContainsKey('ClientName')) {
            throw "Config file '$Path' must define ClientName when automatic client-name resolution is enabled."
        }

        $clientName = $config['ClientName']
        if ($null -eq $clientName) {
            if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
                throw "Config file '$Path' leaves ClientName empty and the COMPUTERNAME environment variable is not available. Set ClientName explicitly or ensure COMPUTERNAME is defined."
            }

            $config['ClientName'] = $env:COMPUTERNAME
        } elseif ($clientName -isnot [string]) {
            throw "Config file '$Path' setting ClientName must be a string or `$null."
        } elseif ([string]::IsNullOrWhiteSpace($clientName)) {
            throw "Config file '$Path' setting ClientName must be a non-empty string or `$null."
        }
    }

    return $config
}

function Test-ToastSqlPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server,[int]$Port=1433)

    $hostName = ($Server -split '\\|,')[0]
    if (-not (Test-NetConnection -ComputerName $hostName -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw "TCP $Port to SQL Server '$hostName' is not reachable."
    }
}

function Get-ToastConnectionString {
    param([hashtable]$Config)

    foreach ($booleanSetting in @('UseIntegratedSecurity','Encrypt','TrustServerCertificate')) {
        if (-not $Config.ContainsKey($booleanSetting)) {
            throw "Config setting $booleanSetting is required."
        }

        if ($Config[$booleanSetting] -isnot [bool]) {
            throw "Config setting $booleanSetting must be `$true or `$false."
        }
    }

    $connectTimeoutSeconds = 15
    if ($Config.ContainsKey('ConnectTimeoutSeconds')) {
        $connectTimeoutSeconds = ConvertTo-ToastPositiveInt -Value $Config['ConnectTimeoutSeconds'] -SettingName 'ConnectTimeoutSeconds'
    }

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$($Config.SqlServer),$($Config.SqlPort)"
    $builder['Initial Catalog'] = $Config.SqlDatabase
    $builder['Encrypt'] = $Config.Encrypt
    $builder['TrustServerCertificate'] = $Config.TrustServerCertificate
    $builder['Connect Timeout'] = $connectTimeoutSeconds

    if ($Config.UseIntegratedSecurity) {
        $builder['Integrated Security'] = $true
        return $builder.ConnectionString
    }

    $builder['Integrated Security'] = $false
    return $builder.ConnectionString
}

function Add-ToastSqlParameter {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlCommand]$Command,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        if ($script:ToastSqlNullParameterDefinitions.ContainsKey($Name)) {
            $parameterDefinition = $script:ToastSqlNullParameterDefinitions[$Name]
            if ($parameterDefinition.ContainsKey('Size')) {
                $p = $Command.Parameters.Add("@$Name", $parameterDefinition.SqlDbType, $parameterDefinition.Size)
            } else {
                $p = $Command.Parameters.Add("@$Name", $parameterDefinition.SqlDbType)
            }
        } else {
            $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::NVarChar, 4000)
        }

        $p.Value = [System.DBNull]::Value
        return
    }

    if ($Value -is [byte[]]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::VarBinary, -1)
        $p.Value = $Value
        return
    }

    if ($Value -is [guid]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::UniqueIdentifier)
        $p.Value = $Value
        return
    }

    if ($Value -is [datetime]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::DateTime2)
        $p.Value = $Value
        return
    }

    if ($Value -is [bool]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::Bit)
        $p.Value = $Value
        return
    }

    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::Int)
        $p.Value = [int]$Value
        return
    }

    if ($Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        if ($Value -is [uint64] -and $Value -gt [uint64][long]::MaxValue) {
            throw "SQL parameter '$Name' cannot exceed Int64::MaxValue."
        }

        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::BigInt)
        $p.Value = [long]$Value
        return
    }

    $stringValue = [string]$Value
    $parameterSize = if ($stringValue.Length -gt 4000) { -1 } else { [math]::Max(1, $stringValue.Length) }
    $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::NVarChar, $parameterSize)
    $p.Value = $stringValue
}

function Get-ToastObjectPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($InputObject -is [System.Data.DataRow]) {
        if ($InputObject.Table.Columns.Contains($PropertyName)) {
            $value = $InputObject[$PropertyName]
            if ($value -is [System.DBNull]) {
                return $null
            }

            return ,$value
        }

        return $null
    }

    $properties = $InputObject.PSObject.Properties.Match($PropertyName)
    if ($properties.Count -gt 0) {
        $value = $properties[0].Value
        if ($value -is [System.DBNull]) {
            return $null
        }

        return ,$value
    }

    return $null
}

function Invoke-ToastSql {
    param(
        [string]$ConnectionString,
        [System.Data.SqlClient.SqlCredential]$SqlCredential,
        [string]$CommandText,
        [hashtable]$Parameters = @{},
        [ValidateRange(1,[int]::MaxValue)][int]$CommandTimeoutSeconds = 30,
        [switch]$NonQuery
    )

    $safeParameters = if ($null -ne $Parameters) { $Parameters } else { @{} }
    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $null
    $reader = $null

    try {
        if ($null -ne $SqlCredential) {
            $connection.Credential = $SqlCredential
        }

        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $CommandText
        $command.CommandTimeout = $CommandTimeoutSeconds

        foreach ($name in $safeParameters.Keys) {
            Add-ToastSqlParameter -Command $command -Name $name -Value $safeParameters[$name]
        }

        if ($NonQuery) {
            [void]$command.ExecuteNonQuery()
            return
        }

        $reader = $command.ExecuteReader()
        $table = [System.Data.DataTable]::new()
        $table.Load($reader)
        Write-Output -NoEnumerate $table
        return
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
    }
}

Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Get-ToastSqlCredential,Invoke-ToastSql,Resolve-ToastRepeatSettings,Resolve-ToastButtonSettings,Resolve-ToastScenario,Resolve-ToastDisplayMode,Resolve-ToastImageInput,Get-ToastNotificationSupportedParameters,Invoke-ToastNotification,Show-ToastAcknowledgementWindow,Set-ToastClientDependencyOptions
