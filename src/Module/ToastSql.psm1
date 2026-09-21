Set-StrictMode -Version Latest

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
    $server = "tcp:$($Config.SqlServer),$($Config.SqlPort)"
    $encrypt = if ($Config.Encrypt) { 'True' } else { 'False' }
    $trust = if ($Config.TrustServerCertificate) { 'True' } else { 'False' }
    if ($Config.UseIntegratedSecurity) {
        return "Server=$server;Database=$($Config.SqlDatabase);Integrated Security=True;Encrypt=$encrypt;TrustServerCertificate=$trust;Connect Timeout=$($Config.CommandTimeoutSeconds);"
    }
    return "Server=$server;Database=$($Config.SqlDatabase);User ID=;Password=;Encrypt=$encrypt;TrustServerCertificate=$trust;Connect Timeout=$($Config.CommandTimeoutSeconds);"
}

function Invoke-ToastSql {
    param([string]$ConnectionString,[string]$CommandText,[hashtable]$Parameters=@{},[switch]$NonQuery)
    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    try {
        $connection.Open(); $command=$connection.CreateCommand(); $command.CommandText=$CommandText; $command.CommandTimeout=30
        foreach($name in $Parameters.Keys) { $p=$command.Parameters.Add("@$name",[System.Data.SqlDbType]::NVarChar,4000); $p.Value=if($null -eq $Parameters[$name]) {[DBNull]::Value} else {$Parameters[$name]} }
        if($NonQuery){[void]$command.ExecuteNonQuery();return}
        $reader=$command.ExecuteReader(); $table=[System.Data.DataTable]::new(); $table.Load($reader); return $table
    } finally {$connection.Dispose()}
}

Export-ModuleMember -Function Test-ToastSqlPort,Get-ToastConnectionString,Invoke-ToastSql
