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

    try {
        $normalizedValue = [int]$Value
    } catch {
        throw "Config file '$Path' setting $SettingName must be a positive integer."
    }

    if ($normalizedValue -le 0) {
        throw "Config file '$Path' setting $SettingName must be a positive integer."
    }

    return $normalizedValue
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
        foreach($name in $Parameters.Keys) { $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::NVarChar,4000); $p.Value=if($null -eq $Parameters[$name]) {[DBNull]::Value} else {$Parameters[$name]} }
        if($NonQuery){[void]$command.ExecuteNonQuery();return}
        $reader=$command.ExecuteReader(); $table=[System.Data.DataTable]::new(); $table.Load($reader); return $table
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
    }
}

Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Get-ToastSqlCredential,Invoke-ToastSql
