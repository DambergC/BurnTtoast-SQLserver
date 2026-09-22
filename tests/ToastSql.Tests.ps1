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

        $builder['Integrated Security'] | Should -BeFalse
        $builder['User ID'] | Should -Be ''
        $builder['Password'] | Should -Be ''
    }
    It 'builds a SqlCredential object from static SqlCredential data' {
        $c=@{SqlServer='sql01';SqlPort=1433;SqlDatabase='ToastNotifications';UseIntegratedSecurity=$false;SqlCredential=@{UserName='toastuser';Password='toastpass'};Encrypt=$true;TrustServerCertificate=$false;CommandTimeoutSeconds=15}
        $credential = Get-ToastSqlCredential $c

        $credential.GetType().FullName | Should -Be 'System.Data.SqlClient.SqlCredential'
        $credential.UserId | Should -Be 'toastuser'
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

    Context 'repeat settings' {
        It 'keeps one-time messages unchanged when repeat settings are omitted' {
            $result = Resolve-ToastRepeatSettings

            $result.RepeatIntervalSeconds | Should -Be $null
            $result.RepeatCount | Should -Be $null
        }

        It 'normalizes minute-based repeats to seconds' {
            $result = Resolve-ToastRepeatSettings -RepeatIntervalMinutes 5 -RepeatCount 3

            $result.RepeatIntervalSeconds | Should -Be 300
            $result.RepeatCount | Should -Be 3
        }

        It 'preserves second-based repeats unchanged' {
            $result = Resolve-ToastRepeatSettings -RepeatIntervalSeconds 45 -RepeatCount 3

            $result.RepeatIntervalSeconds | Should -Be 45
            $result.RepeatCount | Should -Be 3
        }

        It 'rejects repeat counts without an interval' {
            { Resolve-ToastRepeatSettings -RepeatCount 2 } | Should -Throw '*RepeatIntervalSeconds or RepeatIntervalMinutes is required*'
        }

        It 'rejects interval-based repeats without a repeat count' {
            { Resolve-ToastRepeatSettings -RepeatIntervalSeconds 60 } | Should -Throw '*RepeatCount is required*'
        }

        It 'rejects repeat counts smaller than two' {
            { Resolve-ToastRepeatSettings -RepeatIntervalSeconds 60 -RepeatCount 1 } | Should -Throw '*RepeatCount must be 2 or greater*'
        }

        It 'rejects multiple repeat interval units at the same time' {
            { Resolve-ToastRepeatSettings -RepeatIntervalSeconds 60 -RepeatIntervalMinutes 1 -RepeatCount 2 } | Should -Throw '*either RepeatIntervalSeconds or RepeatIntervalMinutes*'
        }

        It 'rejects oversized repeat intervals in minutes' {
            { Resolve-ToastRepeatSettings -RepeatIntervalMinutes 35791395 -RepeatCount 2 } | Should -Throw '*RepeatIntervalMinutes is too large*'
        }
    }

    Context 'button settings' {
        It 'keeps button fields null when button settings are omitted' {
            $result = Resolve-ToastButtonSettings

            $result.ButtonText | Should -Be $null
            $result.ButtonArguments | Should -Be $null
            $result.ButtonActivationType | Should -Be $null
        }

        It 'defaults button activation type to Protocol when text is supplied' {
            $result = Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments 'https://example.test/path'

            $result.ButtonText | Should -Be 'Open'
            $result.ButtonArguments | Should -Be 'https://example.test/path'
            $result.ButtonActivationType | Should -Be 'Protocol'
        }

        It 'allows dismiss buttons without arguments' {
            $result = Resolve-ToastButtonSettings -ButtonText 'Dismiss' -ButtonActivationType 'Dismiss'

            $result.ButtonText | Should -Be 'Dismiss'
            $result.ButtonArguments | Should -Be $null
            $result.ButtonActivationType | Should -Be 'Dismiss'
        }

        It 'rejects button arguments when button text is missing' {
            { Resolve-ToastButtonSettings -ButtonArguments 'https://example.test/path' } | Should -Throw '*ButtonText must be specified*'
        }

        It 'rejects protocol buttons without button arguments' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonActivationType 'Protocol' } | Should -Throw '*ButtonArguments is required*'
        }

        It 'rejects protocol buttons with non-absolute URIs' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments '/relative/path' -ButtonActivationType 'Protocol' } | Should -Throw '*valid absolute URI*'
        }
    }

    Context 'toast notification parameter building' {
        It 'builds BurntToast parameters from optional toast metadata' {
            $row = [pscustomobject]@{
                MessageId = 42
                Title = 'Title'
                Body = 'Body'
                AppLogoPath = 'C:\Toast\logo.png'
                HeroImagePath = 'C:\Toast\hero.png'
                Sound = 'Reminder'
                IsUrgent = $true
            }

            $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','AppLogo','HeroImage','Sound','Urgent')

            $result.Warnings.Count | Should -Be 0
            $result.Parameters.Text | Should -Be @('Title','Body')
            $result.Parameters.AppLogo | Should -Be 'C:\Toast\logo.png'
            $result.Parameters.HeroImage | Should -Be 'C:\Toast\hero.png'
            $result.Parameters.Sound | Should -Be 'Reminder'
            $result.Parameters.Urgent | Should -BeTrue
        }

        It 'skips unsupported optional BurntToast parameters with a warning' {
            $row = [pscustomobject]@{
                MessageId = 7
                Title = 'Title'
                Body = 'Body'
                AppLogoPath = 'C:\Toast\logo.png'
                HeroImagePath = $null
                Sound = ''
                IsUrgent = $true
            }

            $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text')

            @($result.Parameters.Keys) | Should -Be @('Text')
            $result.Warnings.Count | Should -Be 2
            $result.Warnings[0] | Should -Match "AppLogo"
            $result.Warnings[1] | Should -Match "Urgent"
        }

        It 'supports DataRow inputs from SQL results' {
            $table = [System.Data.DataTable]::new()
            [void]$table.Columns.Add('MessageId', [long])
            [void]$table.Columns.Add('Title', [string])
            [void]$table.Columns.Add('Body', [string])
            [void]$table.Columns.Add('AppLogoPath', [string])
            [void]$table.Columns.Add('HeroImagePath', [string])
            [void]$table.Columns.Add('Sound', [string])
            [void]$table.Columns.Add('IsUrgent', [bool])

            $row = $table.NewRow()
            $row.MessageId = 99
            $row.Title = 'Row title'
            $row.Body = 'Row body'
            $row.AppLogoPath = 'C:\Toast\row-logo.png'
            $row.HeroImagePath = 'C:\Toast\row-hero.png'
            $row.Sound = 'Mail'
            $row.IsUrgent = $true
            [void]$table.Rows.Add($row)

            $result = Get-ToastNotificationParameters -ToastRow $table.Rows[0] -SupportedParameters @('Text','AppLogo','HeroImage','Sound','Urgent')

            $result.Warnings.Count | Should -Be 0
            $result.Parameters.Text | Should -Be @('Row title','Row body')
            $result.Parameters.AppLogo | Should -Be 'C:\Toast\row-logo.png'
            $result.Parameters.HeroImage | Should -Be 'C:\Toast\row-hero.png'
            $result.Parameters.Sound | Should -Be 'Mail'
            $result.Parameters.Urgent | Should -BeTrue
        }

        It 'treats DBNull toast metadata as missing values' {
            $table = [System.Data.DataTable]::new()
            [void]$table.Columns.Add('MessageId', [long])
            [void]$table.Columns.Add('Title', [string])
            [void]$table.Columns.Add('Body', [string])
            [void]$table.Columns.Add('AppLogoPath', [string])
            [void]$table.Columns.Add('HeroImagePath', [string])
            [void]$table.Columns.Add('Sound', [string])
            [void]$table.Columns.Add('IsUrgent', [bool])

            $row = $table.NewRow()
            $row.MessageId = 100
            $row.Title = 'DBNull title'
            $row.Body = 'DBNull body'
            $row['AppLogoPath'] = [DBNull]::Value
            $row['HeroImagePath'] = [DBNull]::Value
            $row['Sound'] = [DBNull]::Value
            $row.IsUrgent = $false
            [void]$table.Rows.Add($row)

            $result = Get-ToastNotificationParameters -ToastRow $table.Rows[0] -SupportedParameters @('Text','AppLogo','HeroImage','Sound','Urgent')

            @($result.Parameters.Keys) | Should -Be @('Text')
            $result.Parameters.Text | Should -Be @('DBNull title','DBNull body')
            $result.Warnings.Count | Should -Be 0
        }

        It 'builds a button only when button data and support are present' {
            InModuleScope ToastSql {
                $global:ButtonInvocations = @()
                function New-BTButton {
                    param([string]$Content,[string]$Arguments,[string]$ActivationType)
                    $global:ButtonInvocations += @{
                        Content = $Content
                        Arguments = $Arguments
                        ActivationType = $ActivationType
                    }

                    return [pscustomobject]@{ Kind = 'Button'; Content = $Content }
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 314
                        Title = 'Button title'
                        Body = 'Button body'
                        ButtonText = 'Open'
                        ButtonArguments = 'https://example.test'
                        ButtonActivationType = 'Protocol'
                    }

                    $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','Button')

                    $global:ButtonInvocations.Count | Should -Be 1
                    $global:ButtonInvocations[0].Content | Should -Be 'Open'
                    $global:ButtonInvocations[0].Arguments | Should -Be 'https://example.test'
                    $global:ButtonInvocations[0].ActivationType | Should -Be 'Protocol'
                    $result.Parameters.Button.Count | Should -Be 1
                    $result.Warnings.Count | Should -Be 0
                } finally {
                    Remove-Variable ButtonInvocations -Scope Global -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTButton -ErrorAction SilentlyContinue
                }
            }
        }

        It 'does not build a button when button text is absent' {
            InModuleScope ToastSql {
                $global:ButtonInvocationCount = 0
                function New-BTButton {
                    $global:ButtonInvocationCount++
                    return [pscustomobject]@{ Kind = 'Button' }
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 271
                        Title = 'No button title'
                        Body = 'No button body'
                        ButtonText = $null
                        ButtonArguments = $null
                        ButtonActivationType = $null
                    }

                    $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','Button')

                    $global:ButtonInvocationCount | Should -Be 0
                    $result.Parameters.ContainsKey('Button') | Should -BeFalse
                } finally {
                    Remove-Variable ButtonInvocationCount -Scope Global -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTButton -ErrorAction SilentlyContinue
                }
            }
        }

        It 'emits warnings and splats only supported BurntToast parameters when invoking the client helper' {
            InModuleScope ToastSql {
                $global:ToastWarnings = @()
                function Write-Warning {
                    param([string]$Message)
                    $global:ToastWarnings += $Message
                }

                function New-BurntToastNotification {
                    param($Text,$AppLogo,$HeroImage,$Sound,[switch]$Urgent)
                    $global:ToastInvocation = @{}
                    foreach ($key in $PSBoundParameters.Keys) {
                        $global:ToastInvocation[$key] = $PSBoundParameters[$key]
                    }
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 55
                        Title = 'Helper title'
                        Body = 'Helper body'
                        AppLogoPath = 'C:\Toast\helper-logo.png'
                        HeroImagePath = 'C:\Toast\helper-hero.png'
                        Sound = 'Reminder'
                        IsUrgent = $true
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','AppLogo')

                    $global:ToastWarnings.Count | Should -Be 3
                    $global:ToastInvocation.Text | Should -Be @('Helper title','Helper body')
                    $global:ToastInvocation.AppLogo | Should -Be 'C:\Toast\helper-logo.png'
                    $global:ToastInvocation.ContainsKey('HeroImage') | Should -BeFalse
                    $global:ToastInvocation.ContainsKey('Sound') | Should -BeFalse
                    $global:ToastInvocation.ContainsKey('Urgent') | Should -BeFalse
                } finally {
                    Remove-Variable ToastWarnings -Scope Global -ErrorAction SilentlyContinue
                    Remove-Variable ToastInvocation -Scope Global -ErrorAction SilentlyContinue
                    Remove-Item Function:\Write-Warning -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                }
            }
        }

        It 'derives supported BurntToast parameter names from command discovery' {
            InModuleScope ToastSql {
                function Get-Command {
                    param([string]$Name)
                    if ($Name -ne 'New-BurntToastNotification') {
                        throw "Unexpected command name: $Name"
                    }

                    return [pscustomobject]@{
                        Parameters = [ordered]@{
                            Text = $null
                            AppLogo = $null
                            HeroImage = $null
                        }
                    }
                }

                try {
                    @(Get-ToastNotificationSupportedParameters) | Should -Be @('Text','AppLogo','HeroImage')
                } finally {
                    Remove-Item Function:\Get-Command -ErrorAction SilentlyContinue
                }
            }
        }

        It 'includes Button support only when New-BTButton is available' {
            InModuleScope ToastSql {
                function Get-Command {
                    param([string]$Name)
                    if ($Name -eq 'New-BurntToastNotification') {
                        return [pscustomobject]@{
                            Parameters = [ordered]@{
                                Text = $null
                                Button = $null
                            }
                        }
                    }

                    if ($Name -eq 'New-BTButton') {
                        return [pscustomobject]@{ Parameters = [ordered]@{ Content = $null } }
                    }

                    throw "Unexpected command name: $Name"
                }

                try {
                    @(Get-ToastNotificationSupportedParameters) | Should -Be @('Text','Button')
                } finally {
                    Remove-Item Function:\Get-Command -ErrorAction SilentlyContinue
                }
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

        It 'rejects an empty ClientName string' {
            $configPath = Join-Path $TestDrive 'empty-client-name.psd1'
            Set-Content -Path $configPath -Value @"
@{
    SqlServer = 'sql01'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = `$true
    ClientName = ''
    ClientGroups = @('IT-TEST')
    InternalPowerShellRepository = `$null
    Encrypt = `$true
    TrustServerCertificate = `$false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
"@

            { Import-ToastConfig -Path $configPath -RequiredProperties $requiredClientSettings -NullableProperties $nullableClientSettings -NonEmptyProperties $nonEmptyClientSettings -ResolveClientName } | Should -Throw "*ClientName must be a non-empty string or `$null*"
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
