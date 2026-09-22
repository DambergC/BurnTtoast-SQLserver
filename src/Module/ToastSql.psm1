Set-StrictMode -Version Latest

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

            return $value
        }

        return $null
    }

    $properties = $InputObject.PSObject.Properties.Match($PropertyName)
    if ($properties.Count -gt 0) {
        $value = $properties[0].Value
        if ($value -is [System.DBNull]) {
            return $null
        }

        return $value
    }

    return $null
}

function Get-ToastNotificationParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow,
        [string[]]$SupportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent')
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

    foreach ($mapping in @(
        @{ PropertyName = 'AppLogoPath'; ParameterName = 'AppLogo' },
        @{ PropertyName = 'HeroImagePath'; ParameterName = 'HeroImage' },
        @{ PropertyName = 'Sound'; ParameterName = 'Sound' }
    )) {
        $value = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName $mapping.PropertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            if ($supportedParameterLookup.ContainsKey($mapping.ParameterName)) {
                $parameters[$mapping.ParameterName] = [string]$value
            } else {
                $warnings.Add("Installed BurntToast does not support parameter '$($mapping.ParameterName)'. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without it.")
            }
        }
    }

    $isUrgent = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'IsUrgent'
    if ($null -ne $isUrgent -and [System.Convert]::ToBoolean($isUrgent)) {
        if ($supportedParameterLookup.ContainsKey('Urgent')) {
            $parameters['Urgent'] = $true
        } else {
            $warnings.Add("Installed BurntToast does not support parameter 'Urgent'. MessageId $(Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') will be shown without urgent behavior.")
        }
    }

    return [pscustomobject]@{
        Parameters = $parameters
        Warnings = $warnings.ToArray()
    }
}

function Invoke-ToastNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow,
        [string[]]$SupportedParameters = @('Text','AppLogo','HeroImage','Sound','Urgent')
    )

    $toastDetails = Get-ToastNotificationParameters -ToastRow $ToastRow -SupportedParameters $SupportedParameters
    foreach ($warning in $toastDetails.Warnings) {
        Write-Warning $warning
    }

    $toastParameters = $toastDetails.Parameters
    New-BurntToastNotification @toastParameters
}

function Get-ToastNotificationSupportedParameters {
    [CmdletBinding()]
    param(
        [string]$CommandName = 'New-BurntToastNotification'
    )

    $command = Get-Command $CommandName -ErrorAction Stop
    return @('Text','AppLogo','HeroImage','Sound','Urgent' | Where-Object { $command.Parameters.Contains($_) })
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
        throw "Failed to load config file '$Path': $($_.Exception.Message) PowerShell data files (.psd1) must contain only static values supported by Import-PowerShellDataFile. Replace dynamic expressions with static values or use ClientName = `$null for automatic local computer-name detection."
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
    param([string]$ConnectionString,[System.Data.SqlClient.SqlCredential]$SqlCredential,[string]$CommandText,[hashtable]$Parameters=@{},[ValidateRange(1,[int]::MaxValue)][int]$CommandTimeoutSeconds=30,[switch]$NonQuery)
    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $null
    $reader = $null
    try {
        if ($null -ne $SqlCredential) { $connection.Credential = $SqlCredential }
        $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText=$CommandText; $command.CommandTimeout=$CommandTimeoutSeconds
        foreach($name in $Parameters.Keys) {
            $value = $Parameters[$name]
            if ($null -eq $value) {
                $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::NVarChar,4000)
                $p.Value = [DBNull]::Value
                continue
            }

            if ($value -is [guid]) {
                $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::UniqueIdentifier)
                $p.Value=$value
                continue
            }

            if ($value -is [datetime]) {
                $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::DateTime2)
                $p.Value=$value
                continue
            }

            if ($value -is [bool]) {
                $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::Bit)
                $p.Value=$value
                continue
            }

            if ($value -is [byte] -or $value -is [sbyte] -or $value -is [int16] -or $value -is [uint16] -or $value -is [int32]) {
                $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::Int)
                $p.Value=[int]$value
                continue
            }

            if ($value -is [uint32] -or $value -is [int64] -or $value -is [uint64]) {
                $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::BigInt)
                $p.Value=[long]$value
                continue
            }

            $stringValue = [string]$value
            $parameterSize = if ($stringValue.Length -gt 4000) { -1 } else { [math]::Max(1,$stringValue.Length) }
            $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::NVarChar,$parameterSize)
            $p.Value=$stringValue
        }
        if($NonQuery){[void]$command.ExecuteNonQuery();return}
        $reader=$command.ExecuteReader(); $table=[System.Data.DataTable]::new(); $table.Load($reader); return $table
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
    }
}

Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Get-ToastSqlCredential,Invoke-ToastSql,Resolve-ToastRepeatSettings,Get-ToastNotificationParameters,Invoke-ToastNotification,Get-ToastNotificationSupportedParameters
