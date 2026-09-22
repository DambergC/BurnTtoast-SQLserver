# Configuration used by the scripts. Copy to config.psd1 and edit values.
@{
    SqlServer = 'SQLSERVER.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = $true
    # Only use when required; obtain credentials interactively or from a secure vault.
    SqlCredential = $null
    # PSD1 values must be static. Leave as $null to auto-detect the local computer name in the client script.
    ClientName = $null
    ClientGroups = @('IT-TEST')
    BurntToastModulePath = $null
    InternalPowerShellRepository = $null
    Encrypt = $true
    TrustServerCertificate = $false
    CommandTimeoutSeconds = 15
}
