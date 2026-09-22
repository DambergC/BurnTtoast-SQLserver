$modulePath = Join-Path $PSScriptRoot '..\src\Module\ToastSql.psm1'
Import-Module $modulePath -Force

Describe 'ToastSql module' {
    It 'builds a valid SQL connection string for integrated security' {
        $config = @{
            SqlServer = 'sql01'
            SqlPort = 1433
            SqlDatabase = 'ToastNotifications'
            UseIntegratedSecurity = $true
            Encrypt = $true
            TrustServerCertificate = $false
            ConnectTimeoutSeconds = 15
        }

        $connectionString = Get-ToastConnectionString $config
        $connectionString | Should -Match 'Data Source=tcp:sql01,1433'
        $connectionString | Should -Match 'Initial Catalog=ToastNotifications'
        $connectionString | Should -Match 'Integrated Security=True'
    }

    It 'builds a valid SQL connection string for SQL credential auth' {
        $config = @{
            SqlServer = 'sql01'
            SqlPort = 1433
            SqlDatabase = 'ToastNotifications'
            UseIntegratedSecurity = $false
            Encrypt = $true
            TrustServerCertificate = $false
            ConnectTimeoutSeconds = 15
        }

        $connectionString = Get-ToastConnectionString $config
        $connectionString | Should -Match 'Integrated Security=False'
    }

    It 'rejects non-boolean connection flags when building a connection string' {
        $config = @{
            SqlServer = 'sql01'
            SqlPort = 1433
            SqlDatabase = 'ToastNotifications'
            UseIntegratedSecurity = $true
            Encrypt = 'false'
            TrustServerCertificate = $false
            CommandTimeoutSeconds = 15
        }

        { Get-ToastConnectionString $config } | Should -Throw '*Config setting Encrypt must be $true or $false*'
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
        It 'returns nulls when no button data is supplied' {
            $result = Resolve-ToastButtonSettings -ButtonText $null -ButtonArguments $null

            $result.ButtonText | Should -Be $null
            $result.ButtonArguments | Should -Be $null
            $result.ButtonActivationType | Should -Be $null
        }

        It 'rejects invalid button activation type values' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments 'https://example.com' -ButtonActivationType 'Bogus' } |
                Should -Throw '*Protocol,Dismiss*'
        }

        It 'requires ButtonArguments for a Protocol action button' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonActivationType 'Protocol' } |
                Should -Throw '*ButtonArguments is required when ButtonActivationType is Protocol*'
        }

        It 'accepts a valid Dismiss button without arguments' {
            $result = Resolve-ToastButtonSettings -ButtonText 'Dismiss' -ButtonActivationType 'Dismiss'

            $result.ButtonText | Should -Be 'Dismiss'
            $result.ButtonArguments | Should -Be $null
            $result.ButtonActivationType | Should -Be 'Dismiss'
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

            $result.Parameters.Text.Count | Should -Be 2
            $result.Parameters.AppLogo | Should -Be 'C:\Toast\logo.png'
            $result.Parameters.HeroImage | Should -Be 'C:\Toast\hero.png'
            $result.Parameters.Sound | Should -Be 'Reminder'
            $result.Parameters.Urgent | Should -Be $true
        }

        It 'allows optional sound to be null without strict-mode errors' {
            $row = [pscustomobject]@{
                MessageId = 42
                Title = 'Title'
                Body = 'Body'
                AppLogoPath = $null
                HeroImagePath = $null
                IsUrgent = $false
            }

            $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','AppLogo','HeroImage','Sound','Urgent')

            $result.Parameters.ContainsKey('Text') | Should -Be $true
            $result.Parameters.ContainsKey('Sound') | Should -Be $false
        }

        It 'adds a button when supported and available' {
            InModuleScope ToastSql {
                function New-BTButton {
                    param(
                        [string]$Content,
                        [string]$ActivationType,
                        [string]$Arguments
                    )
                }

                Mock New-BTButton {
                    param(
                        $Content,
                        $ActivationType,
                        $Arguments,
                        [switch]$Dismiss
                    )

                    [pscustomobject]@{
                        BoundParameters = @{} + $PSBoundParameters
                    }
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        ButtonText = 'Open'
                        ButtonArguments = 'https://example.com'
                        ButtonActivationType = 'Protocol'
                    }

                    $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','Button')

                    $result.Parameters.ContainsKey('Button') | Should -Be $true
                } finally {
                    Remove-Item Function:\New-BTButton -ErrorAction SilentlyContinue
                }
            }
        }

        It 'passes Protocol activation to New-BTButton' {
            InModuleScope ToastSql {
                function New-BTButton {
                    param(
                        [string]$Content,
                        [string]$ActivationType,
                        [string]$Arguments
                    )
                }

                Mock New-BTButton {
                    param(
                        $Content,
                        $ActivationType,
                        $Arguments,
                        [switch]$Dismiss
                    )

                    [pscustomobject]@{
                        BoundParameters = @{} + $PSBoundParameters
                    }
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        ButtonText = 'Open'
                        ButtonArguments = 'https://example.com'
                        ButtonActivationType = 'Protocol'
                    }

                    $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','Button')

                    $result.Parameters.Button.BoundParameters['Content'] | Should -Be 'Open'
                    $result.Parameters.Button.BoundParameters['ActivationType'] | Should -Be 'Protocol'
                    $result.Parameters.Button.BoundParameters['Arguments'] | Should -Be 'https://example.com'
                    $result.Parameters.Button.BoundParameters.ContainsKey('Dismiss') | Should -Be $false
                } finally {
                    Remove-Item Function:\New-BTButton -ErrorAction SilentlyContinue
                }
            }
        }

        It 'uses the dismiss switch instead of ActivationType for dismiss buttons' {
            InModuleScope ToastSql {
                function New-BTButton {
                    param(
                        [string]$Content,
                        [switch]$Dismiss
                    )
                }

                Mock New-BTButton {
                    param(
                        $Content,
                        $ActivationType,
                        $Arguments,
                        [switch]$Dismiss
                    )

                    [pscustomobject]@{
                        BoundParameters = @{} + $PSBoundParameters
                    }
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        ButtonText = 'Dismiss'
                        ButtonArguments = $null
                        ButtonActivationType = 'Dismiss'
                    }

                    $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','Button')

                    $result.Parameters.Button.BoundParameters['Content'] | Should -Be 'Dismiss'
                    $result.Parameters.Button.BoundParameters['Dismiss'] | Should -Be $true
                    $result.Parameters.Button.BoundParameters.ContainsKey('ActivationType') | Should -Be $false
                    $result.Parameters.Button.BoundParameters.ContainsKey('Arguments') | Should -Be $false
                } finally {
                    Remove-Item Function:\New-BTButton -ErrorAction SilentlyContinue
                }
            }
        }

        It 'warns and omits dismiss buttons when BurntToast lacks dismiss support' {
            InModuleScope ToastSql {
                function New-BTButton {
                    param(
                        [string]$Content,
                        [string]$ActivationType,
                        [string]$Arguments
                    )
                }

                Mock New-BTButton {}

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        ButtonText = 'Dismiss'
                        ButtonArguments = $null
                        ButtonActivationType = 'Dismiss'
                    }

                    $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','Button')

                    $result.Parameters.ContainsKey('Button') | Should -Be $false
                    $result.Warnings.Count | Should -Be 1
                    $result.Warnings[0] | Should -Match 'does not support dismiss action buttons'
                    Should -Invoke New-BTButton -Times 0
                } finally {
                    Remove-Item Function:\New-BTButton -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'parameter binding' {
        It 'adds all supplied parameters to the SQL command' {
            $params = @{
                GroupName = 'g'
                Title = 't'
                Body = 'b'
                Sound = $null
                IsUrgent = $false
                RepeatIntervalSeconds = $null
                RepeatCount = $null
                ButtonText = $null
                ButtonArguments = $null
                ButtonActivationType = $null
            }

            $cmd = [System.Data.SqlClient.SqlCommand]::new()
            foreach ($name in $params.Keys) {
                $value = $params[$name]
                if ($null -eq $value) {
                    $p = $cmd.Parameters.Add("@$name", [System.Data.SqlDbType]::NVarChar, 4000)
                    $p.Value = [System.DBNull]::Value
                    continue
                }

                $stringValue = [string]$value
                $parameterSize = if ($stringValue.Length -gt 4000) { -1 } else { [math]::Max(1, $stringValue.Length) }
                $p = $cmd.Parameters.Add("@$name", [System.Data.SqlDbType]::NVarChar, $parameterSize)
                $p.Value = $stringValue
            }

            $cmd.Parameters.Contains('@GroupName') | Should -Be $true
            $cmd.Parameters.Contains('@Title') | Should -Be $true
            $cmd.Parameters.Contains('@Body') | Should -Be $true
            $cmd.Parameters.Contains('@ButtonText') | Should -Be $true
        }
    }

    Context 'local-time reporting SQL compatibility' {
        It 'keeps @TimeZoneName parameters but does not perform UTC timezone conversion' {
            $scriptPath = Join-Path $PSScriptRoot '..\sql\004-local-time-reporting.sql'
            $scriptText = Get-Content -Path $scriptPath -Raw

            $scriptText | Should -Match 'ufn_ToastMessageLocal\s*\r?\n\(\r?\n\s*@TimeZoneName sysname = NULL'
            $scriptText | Should -Match 'ufn_ToastDeliveryLocal\s*\r?\n\(\r?\n\s*@TimeZoneName sysname = NULL'
            $scriptText | Should -Not -Match "AT TIME ZONE ''UTC''"
        }
    }
}
