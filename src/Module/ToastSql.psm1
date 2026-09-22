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
        if ($null -ne $clientName -and $clientName -isnot [string]) {
            throw "Config file '$Path' setting ClientName must be a string or `$null."
        }

        if ([string]::IsNullOrWhiteSpace($clientName)) {
            if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
                throw "Config file '$Path' leaves ClientName empty and the COMPUTERNAME environment variable is not available. Set ClientName explicitly or ensure COMPUTERNAME is defined."
            }

            $config['ClientName'] = $env:COMPUTERNAME
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
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$($Config.SqlServer),$($Config.SqlPort)"
    $builder['Initial Catalog'] = $Config.SqlDatabase
    $builder['Encrypt'] = [bool]$Config.Encrypt
    $builder['TrustServerCertificate'] = [bool]$Config.TrustServerCertificate

    if ($Config.UseIntegratedSecurity) {
        $builder['Integrated Security'] = $true
        return $builder.ConnectionString
    }

    if (-not $Config.ContainsKey('SqlCredential') -or $null -eq $Config['SqlCredential']) {
        throw "Config setting SqlCredential is required when UseIntegratedSecurity = `$false."
    }

    $credential = Get-ToastSqlCredentialValues -SqlCredential $Config['SqlCredential']
    $builder['User ID'] = $credential.UserName
    $builder['Password'] = $credential.Password
    return $builder.ConnectionString
}

function Invoke-ToastSql {
    param([string]$ConnectionString,[string]$CommandText,[hashtable]$Parameters=@{},[int]$CommandTimeoutSeconds=30,[switch]$NonQuery)
    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    try {
        $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText=$CommandText; $command.CommandTimeout=$CommandTimeoutSeconds
        foreach($name in $Parameters.Keys) { $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::NVarChar,4000); $p.Value=if($null -eq $Parameters[$name]) {[DBNull]::Value} else {$Parameters[$name]} }
        if($NonQuery){[void]$command.ExecuteNonQuery();return}
        $reader=$command.ExecuteReader(); $table=[System.Data.DataTable]::new(); $table.Load($reader); return $table
    } finally {$connection.Dispose()}
}

Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Invoke-ToastSql
