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
$script:ToastSupportedScenarios = @('Default','Reminder','Alarm','IncomingCall')
$script:ToastSqlNullParameterDefinitions = @{
    AppLogoBytes = @{ SqlDbType = [System.Data.SqlDbType]::VarBinary; Size = -1 }
    HeroImageBytes = @{ SqlDbType = [System.Data.SqlDbType]::VarBinary; Size = -1 }
    AppLogoContentType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 100 }
    HeroImageContentType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 100 }
    Sound = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    IsUrgent = @{ SqlDbType = [System.Data.SqlDbType]::Bit }
    RepeatIntervalSeconds = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    RepeatCount = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    MessageId = @{ SqlDbType = [System.Data.SqlDbType]::BigInt }
    LeaseId = @{ SqlDbType = [System.Data.SqlDbType]::UniqueIdentifier }
    ExpiresUtc = @{ SqlDbType = [System.Data.SqlDbType]::DateTime2 }
    ButtonActivationType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
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

    $isIntegral = $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
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

        return @{
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
        return @{
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
    return @{
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
    if ($script:ToastSupportedScenarios -notcontains $normalizedScenario) {
        throw "Scenario must be one of: $($script:ToastSupportedScenarios -join ', ')."
    }

    return $normalizedScenario
}

function ConvertTo-ToastSoundSourceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sound
    )

    $normalizedSound = $Sound.Trim()
    switch ($normalizedSound) {
        'Default' { return 'ms-winsoundevent:Notification.Default' }
        'IM' { return 'ms-winsoundevent:Notification.IM' }
        'Mail' { return 'ms-winsoundevent:Notification.Mail' }
        'Reminder' { return 'ms-winsoundevent:Notification.Reminder' }
        'SMS' { return 'ms-winsoundevent:Notification.SMS' }
        'Alarm' { return 'ms-winsoundevent:Notification.Looping.Alarm' }
        'Call' { return 'ms-winsoundevent:Notification.Looping.Call' }
        default {
            if ($normalizedSound -match '^Alarm([2-9]|10)$') {
                return "ms-winsoundevent:Notification.Looping.$normalizedSound"
            }

            if ($normalizedSound -match '^Call([2-9]|10)$') {
                return "ms-winsoundevent:Notification.Looping.$normalizedSound"
            }
        }
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

function Invoke-ToastNotificationWithScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ToastParameters,
        [Parameter(Mandatory)][string]$Scenario,
        [AllowNull()][long]$MessageId
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $newBurntToastCommand = Get-Command 'New-BurntToastNotification' -ErrorAction Stop

    if ($newBurntToastCommand.Parameters.Keys -contains 'Scenario') {
        $toastWithScenario = @{} + $ToastParameters
        $toastWithScenario['Scenario'] = $Scenario
        $invocationDetails = Get-ToastBurntToastInvocationDetails -ToastParameters $toastWithScenario -BurntToastCommand $newBurntToastCommand -MessageId $MessageId
        foreach ($warning in $invocationDetails.Warnings) {
            $warnings.Add($warning)
        }

        $scenarioInvocationParameters = $invocationDetails.Parameters
        New-BurntToastNotification @scenarioInvocationParameters
        return $warnings.ToArray()
    }

    $newBtContentCommand = Get-Command 'New-BTContent' -ErrorAction SilentlyContinue
    $newBtVisualCommand = Get-Command 'New-BTVisual' -ErrorAction SilentlyContinue
    $newBtBindingCommand = Get-Command 'New-BTBinding' -ErrorAction SilentlyContinue
    $newBtTextCommand = Get-Command 'New-BTText' -ErrorAction SilentlyContinue
    $submitBtNotificationCommand = Get-Command 'Submit-BTNotification' -ErrorAction SilentlyContinue

    if (
        $null -eq $newBtContentCommand -or
        $null -eq $newBtVisualCommand -or
        $null -eq $newBtBindingCommand -or
        $null -eq $newBtTextCommand -or
        $null -eq $submitBtNotificationCommand -or
        -not ($newBtContentCommand.Parameters.Keys -contains 'Scenario') -or
        -not ($newBtVisualCommand.Parameters.Keys -contains 'BindingGeneric') -or
        -not ($newBtBindingCommand.Parameters.Keys -contains 'Children')
    ) {
        $warnings.Add("Installed BurntToast version does not support persistent toast scenario '$Scenario'. MessageId $MessageId will be shown as a default toast.")
        $fallbackInvocationDetails = Get-ToastBurntToastInvocationDetails -ToastParameters $ToastParameters -BurntToastCommand $newBurntToastCommand -MessageId $MessageId
        foreach ($warning in $fallbackInvocationDetails.Warnings) {
            $warnings.Add($warning)
        }

        $fallbackInvocationParameters = $fallbackInvocationDetails.Parameters
        New-BurntToastNotification @fallbackInvocationParameters
        return $warnings.ToArray()
    }

    $children = [System.Collections.Generic.List[object]]::new()
    foreach ($textPart in @($ToastParameters['Text'])) {
        if ([string]::IsNullOrWhiteSpace([string]$textPart)) {
            continue
        }

        if ($newBtTextCommand.Parameters.Keys -contains 'Text') {
            $children.Add((New-BTText -Text ([string]$textPart)))
        } else {
            $children.Add((New-BTText -Content ([string]$textPart)))
        }
    }

    if ($children.Count -eq 0) {
        if ($newBtTextCommand.Parameters.Keys -contains 'Text') {
            $children.Add((New-BTText -Text ''))
        } else {
            $children.Add((New-BTText -Content ''))
        }
    }

    $bindingParameters = @{
        Children = $children.ToArray()
    }

    $newBtImageCommand = Get-Command 'New-BTImage' -ErrorAction SilentlyContinue
    $canBuildAppLogoImage = $null -ne $newBtImageCommand -and ($newBtImageCommand.Parameters.Keys -contains 'Source') -and ($newBtImageCommand.Parameters.Keys -contains 'AppLogoOverride')
    $canBuildHeroImage = $null -ne $newBtImageCommand -and ($newBtImageCommand.Parameters.Keys -contains 'Source') -and ($newBtImageCommand.Parameters.Keys -contains 'HeroImage')
    if ($ToastParameters.ContainsKey('AppLogo') -and -not [string]::IsNullOrWhiteSpace([string]$ToastParameters['AppLogo'])) {
        if ($canBuildAppLogoImage -and $newBtBindingCommand.Parameters.Keys -contains 'AppLogoOverride') {
            $bindingParameters['AppLogoOverride'] = New-BTImage -Source ([string]$ToastParameters['AppLogo']) -AppLogoOverride
        } else {
            $warnings.Add("Installed BurntToast version does not support app-logo rendering for persistent scenario '$Scenario'. MessageId $MessageId will be shown without app-logo image.")
        }
    }

    if ($ToastParameters.ContainsKey('HeroImage') -and -not [string]::IsNullOrWhiteSpace([string]$ToastParameters['HeroImage'])) {
        if ($canBuildHeroImage -and $newBtBindingCommand.Parameters.Keys -contains 'HeroImage') {
            $bindingParameters['HeroImage'] = New-BTImage -Source ([string]$ToastParameters['HeroImage']) -HeroImage
        } else {
            $warnings.Add("Installed BurntToast version does not support hero-image rendering for persistent scenario '$Scenario'. MessageId $MessageId will be shown without hero image.")
        }
    }

    $binding = New-BTBinding @bindingParameters
    $visual = New-BTVisual -BindingGeneric $binding
    $contentParameters = @{
        Visual = $visual
        Scenario = $Scenario
    }

    if ($ToastParameters.ContainsKey('Button')) {
        $newBtActionCommand = Get-Command 'New-BTAction' -ErrorAction SilentlyContinue
        if (
            $null -ne $newBtActionCommand -and
            ($newBtActionCommand.Parameters.Keys -contains 'Buttons') -and
            ($newBtContentCommand.Parameters.Keys -contains 'Actions')
        ) {
            $contentParameters['Actions'] = New-BTAction -Buttons @($ToastParameters['Button'])
        } else {
            $warnings.Add("Installed BurntToast version does not support button actions for persistent scenario '$Scenario'. MessageId $MessageId will be shown without buttons.")
        }
    }

    if ($ToastParameters.ContainsKey('Sound')) {
        $newBtAudioCommand = Get-Command 'New-BTAudio' -ErrorAction SilentlyContinue
        if (
            $null -ne $newBtAudioCommand -and
            ($newBtAudioCommand.Parameters.Keys -contains 'Source') -and
            ($newBtContentCommand.Parameters.Keys -contains 'Audio')
        ) {
            $soundSource = ConvertTo-ToastSoundSourceUri -Sound ([string]$ToastParameters['Sound'])
            if ([string]::IsNullOrWhiteSpace($soundSource)) {
                $warnings.Add("Unsupported sound value '$($ToastParameters['Sound'])' for persistent scenario '$Scenario'. MessageId $MessageId will be shown without custom sound.")
            } else {
                $contentParameters['Audio'] = New-BTAudio -Source $soundSource
            }
        } else {
            $warnings.Add("Installed BurntToast version does not support sound rendering for persistent scenario '$Scenario'. MessageId $MessageId will be shown without custom sound.")
        }
    }

    $content = New-BTContent @contentParameters
    $submitParameters = @{
        Content = $content
    }

    if ($ToastParameters.ContainsKey('Urgent') -and [System.Convert]::ToBoolean($ToastParameters['Urgent'])) {
        if ($submitBtNotificationCommand.Parameters.Keys -contains 'Urgent') {
            $submitParameters['Urgent'] = $true
        } else {
            $warnings.Add("Installed BurntToast version does not support urgent delivery for persistent scenario '$Scenario'. MessageId $MessageId will be shown without urgent delivery.")
        }
    }

    Submit-BTNotification @submitParameters
    return $warnings.ToArray()
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

function Get-ToastNotificationParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow,
        [string[]]$SupportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent','Button')
    )

    $supportedParameterLookup = @{}
    foreach ($parameterName in $SupportedParameters) {
        $supportedParameterLookup[$parameterName] = $true
    }

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

    $isUrgent = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'IsUrgent'
    if ($null -ne $isUrgent -and [System.Convert]::ToBoolean($isUrgent)) {
        if ($supportedParameterLookup.ContainsKey('Urgent')) {
            $parameters['Urgent'] = $true
        } else {
            $warnings.Add("Installed BurntToast does not support parameter 'Urgent'. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without urgent styling.")
        }
    }

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
                    $warnings.Add("Installed BurntToast version does not support dismiss action buttons. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without a button.")
                }
            } else {
                $newButtonParameters['ActivationType'] = $resolvedButtonActivationType
                if (-not [string]::IsNullOrWhiteSpace([string]$buttonArguments)) {
                    $newButtonParameters['Arguments'] = [string]$buttonArguments
                }

                $parameters['Button'] = New-BTButton @newButtonParameters
            }
        } else {
            $warnings.Add("Installed BurntToast does not support button actions. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without a button.")
        }
    }

    return [pscustomobject]@{
        Parameters = $parameters
        TemporaryFiles = $temporaryFiles.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Invoke-ToastNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow,
        [string[]]$SupportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent','Button')
    )

    $toastDetails = Get-ToastNotificationParameters -ToastRow $ToastRow -SupportedParameters $SupportedParameters
    foreach ($warning in $toastDetails.Warnings) {
        Write-Warning $warning
    }

    $toastParameters = $toastDetails.Parameters
    $messageId = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId'
    $scenario = 'Default'
    $scenarioValue = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Scenario'
    if (-not [string]::IsNullOrWhiteSpace([string]$scenarioValue)) {
        try {
            $scenario = Resolve-ToastScenario -Scenario ([string]$scenarioValue)
        } catch {
            Write-Warning "Invalid toast scenario '$scenarioValue' for MessageId $messageId. Falling back to Default."
            $scenario = 'Default'
        }
    }

    try {
        if ($scenario -eq 'Default') {
            $newBurntToastCommand = Get-Command 'New-BurntToastNotification' -ErrorAction Stop
            $invocationDetails = Get-ToastBurntToastInvocationDetails -ToastParameters $toastParameters -BurntToastCommand $newBurntToastCommand -MessageId $messageId
            foreach ($warning in $invocationDetails.Warnings) {
                Write-Warning $warning
            }

            $defaultScenarioInvocationParameters = $invocationDetails.Parameters
            New-BurntToastNotification @defaultScenarioInvocationParameters
        } else {
            $scenarioWarnings = Invoke-ToastNotificationWithScenario -ToastParameters $toastParameters -Scenario $scenario -MessageId $messageId
            foreach ($warning in $scenarioWarnings) {
                Write-Warning $warning
            }
        }
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

    $newBtContentCommand = Get-Command 'New-BTContent' -ErrorAction SilentlyContinue
    $newBtBindingCommand = Get-Command 'New-BTBinding' -ErrorAction SilentlyContinue
    $newBtImageCommand = Get-Command 'New-BTImage' -ErrorAction SilentlyContinue
    $newBtActionCommand = Get-Command 'New-BTAction' -ErrorAction SilentlyContinue
    $newBtAudioCommand = Get-Command 'New-BTAudio' -ErrorAction SilentlyContinue
    $submitBtNotificationCommand = Get-Command 'Submit-BTNotification' -ErrorAction SilentlyContinue

    if ($null -ne $newBtImageCommand -and $null -ne $newBtBindingCommand) {
        if ($newBtBindingCommand.Parameters.Keys -contains 'AppLogoOverride') {
            $supportedParameters += 'AppLogo'
        }

        if ($newBtBindingCommand.Parameters.Keys -contains 'HeroImage') {
            $supportedParameters += 'HeroImage'
        }
    }

    if (
        $hasButtonCommand -and
        $null -ne $newBtActionCommand -and
        $null -ne $newBtContentCommand -and
        ($newBtActionCommand.Parameters.Keys -contains 'Buttons') -and
        ($newBtContentCommand.Parameters.Keys -contains 'Actions')
    ) {
        $supportedParameters += 'Button'
    }

    if (
        $null -ne $newBtAudioCommand -and
        $null -ne $newBtContentCommand -and
        ($newBtAudioCommand.Parameters.Keys -contains 'Source') -and
        ($newBtContentCommand.Parameters.Keys -contains 'Audio')
    ) {
        $supportedParameters += 'Sound'
    }

    if ($null -ne $submitBtNotificationCommand -and ($submitBtNotificationCommand.Parameters.Keys -contains 'Urgent')) {
        $supportedParameters += 'Urgent'
    }

    return @($supportedParameters | Select-Object -Unique)
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


Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Get-ToastSqlCredential,Invoke-ToastSql,Resolve-ToastRepeatSettings,Resolve-ToastButtonSettings,Resolve-ToastQueueResult,Resolve-ToastImageInput,Get-ToastNotificationParameters,Invoke-ToastNotification,Get-ToastNotificationSupportedParameters
