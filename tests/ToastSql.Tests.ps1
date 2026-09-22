Describe 'ToastSql module' {
    BeforeAll { Import-Module "$PSScriptRoot\..\src\Module\ToastSql.psm1" -Force }
    It 'builds an explicit TCP 1433 connection string' {
        $c=@{SqlServer='sql01';SqlPort=1433;SqlDatabase='ToastNotifications';UseIntegratedSecurity=$true;Encrypt=$true;TrustServerCertificate=$false;CommandTimeoutSeconds=15}
        Get-ToastConnectionString $c | Should -Match 'tcp:sql01,1433'
    }
    It 'uses ConnectTimeoutSeconds for the SQL connect timeout' {
        $c=@{SqlServer='sql01';SqlPort=1433;SqlDatabase='ToastNotifications';UseIntegratedSecurity=$true;Encrypt=$true;TrustServerCertificate=$false;ConnectTimeoutSeconds=42;CommandTimeoutSeconds=15}
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new((Get-ToastConnectionString $c))

        $builder['Connect Timeout'] | Should -Be 42
    }
    It 'builds a SQL authentication connection string from static SqlCredential data' {
        $c=@{SqlServer='sql01';SqlPort=1433;SqlDatabase='ToastNotifications';UseIntegratedSecurity=$false;SqlCredential=@{UserName='toastuser';Password='toastpass'};Encrypt=$true;TrustServerCertificate=$false;CommandTimeoutSeconds=15}
        $connectionString = Get-ToastConnectionString $c
        $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($connectionString)

        $builder['User ID'] | Should -Be 'toastuser'
        $builder['Password'] | Should -Be 'toastpass'
    }
    It 'rejects non-boolean connection flags when building a connection string' {
        $c=@{SqlServer='sql01';SqlPort=1433;SqlDatabase='ToastNotifications';UseIntegratedSecurity=$true;Encrypt='false';TrustServerCertificate=$false;CommandTimeoutSeconds=15}
        { Get-ToastConnectionString $c } | Should -Throw '*Config setting Encrypt must be $true or $false*'
    }
    It 'rejects an unreachable SQL port' {
        InModuleScope ToastSql {
            function Test-NetConnection { $false }
            try {
                { Test-ToastSqlPort -Server 'invalid.example' -Port 1433 } | Should -Throw
            } finally {
                Remove-Item Function:\Test-NetConnection -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'config loading' {
        BeforeAll {
            $requiredClientSettings = @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','ClientName','ClientGroups','InternalPowerShellRepository','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds')
            $nullableClientSettings = @('ClientName','InternalPowerShellRepository')
            $nonEmptyClientSettings = @('ClientGroups')
            $originalComputerName = $env:COMPUTERNAME
            $env:COMPUTERNAME = 'TESTHOST'
        }

        AfterAll {
            $env:COMPUTERNAME = $originalComputerName
        }

        It 'keeps the example config importable by Import-PowerShellDataFile' {
            $examplePath = Join-Path $PSScriptRoot '..\config\config.example.psd1'
            $exampleConfig = Import-PowerShellDataFile -Path $examplePath

            $exampleConfig.ClientName | Should -Be $null
        }

        It 'uses COMPUTERNAME when ClientName is null' {
            $configPath = Join-Path $TestDrive 'config.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            $config = Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName

            $config.ClientName | Should -Be 'TESTHOST'
        }

        It 'preserves an explicit ClientName' {
            $configPath = Join-Path $TestDrive 'static-config.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = 'STATIC-CLIENT'
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            $config = Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName

            $config.ClientName | Should -Be 'STATIC-CLIENT'
        }

        It 'throws a clear error for dynamic PSD1 expressions' {
            $configPath = Join-Path $TestDrive 'dynamic-config.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$env:COMPUTERNAME
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*Failed to load config file*ClientName = `$null*"
        }

        It 'throws a clear error when required settings are missing' {
            $configPath = Join-Path $TestDrive 'missing-setting.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*missing required setting(s): SqlServer*"
        }

        It 'rejects a non-string ClientName value' {
            $configPath = Join-Path $TestDrive 'invalid-client-name.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = 0
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*ClientName must be a string or `$null*"
        }

        It 'rejects an empty required SqlServer setting' {
            $configPath = Join-Path $TestDrive 'empty-sql-server.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = `$null
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*empty required setting(s): SqlServer*"
        }

        It 'rejects an empty ClientGroups array' {
            $configPath = Join-Path $TestDrive 'empty-client-groups.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @()
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*at least one value for: ClientGroups*"
        }

        It 'requires SqlCredential when integrated security is disabled' {
            $configPath = Join-Path $TestDrive 'sql-auth.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$false
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*SqlCredential must be provided*"
        }

        It 'accepts static SqlCredential data when integrated security is disabled' {
            $configPath = Join-Path $TestDrive 'sql-auth-valid.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$false
    SqlCredential = @{
        UserName = 'toastuser'
        Password = 'toastpass'
    }
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            $config = Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName

            $config.UseIntegratedSecurity | Should -BeFalse
            $config.SqlCredential.UserName | Should -Be 'toastuser'
        }

        It 'rejects a non-boolean UseIntegratedSecurity value' {
            $configPath = Join-Path $TestDrive 'invalid-integrated-security.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = 'false'
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*UseIntegratedSecurity must be `$true or `$false*"
        }

        It 'rejects a non-boolean Encrypt value' {
            $configPath = Join-Path $TestDrive 'invalid-encrypt.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = 'false'
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*Encrypt must be `$true or `$false*"
        }

        It 'rejects a non-positive ConnectTimeoutSeconds value' {
            $configPath = Join-Path $TestDrive 'invalid-connect-timeout.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 0
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*ConnectTimeoutSeconds must be a positive integer*"
        }

        It 'rejects a non-positive CommandTimeoutSeconds value' {
            $configPath = Join-Path $TestDrive 'invalid-command-timeout.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = `$null
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 0
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*CommandTimeoutSeconds must be a positive integer*"
        }
    }
}
