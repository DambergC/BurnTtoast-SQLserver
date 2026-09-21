# Configuration used by the scripts. Copy to config.psd1 and edit values.
@{
    SqlServer = 'SQLSERVER.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = $true
    # Only use when required; obtain credentials interactively or from a secure vault.
    SqlCredential = $null
    ClientName = $env:COMPUTERNAME
    ClientGroups = @('IT-TEST')
    BurntToastModulePath = $null
    InternalPowerShellRepository = $null
    Encrypt = $true
    TrustServerCertificate = $false
    CommandTimeoutSeconds = 15
}
