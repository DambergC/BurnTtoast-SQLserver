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

    Context 'scenario settings' {
        It 'defaults empty scenarios to Default' {
            InModuleScope ToastSql {
                Resolve-ToastScenario -Scenario $null | Should -Be 'Default'
                Resolve-ToastScenario -Scenario '   ' | Should -Be 'Default'
            }
        }

        It 'rejects unsupported scenario values' {
            InModuleScope ToastSql {
                { Resolve-ToastScenario -Scenario 'Persistent' } | Should -Throw '*Scenario must be one of*'
            }
        }
    }

    Context 'image input resolution' {
        It 'reads image bytes from a file path and infers the content type' {
            InModuleScope ToastSql {
                $filePath = Join-Path ([System.IO.Path]::GetTempPath()) "toastsql-test-$([guid]::NewGuid().ToString('N')).png"
                $expectedBytes = [byte[]](137,80,78,71,13,10,26,10)

                try {
                    [System.IO.File]::WriteAllBytes($filePath, $expectedBytes)

                    $result = Resolve-ToastImageInput -FilePath $filePath -ParameterName 'AppLogo'

                    $result.ContentType | Should -Be 'image/png'
                    ($result.ImageBytes -join ',') | Should -Be ($expectedBytes -join ',')
                } finally {
                    Remove-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'rejects empty binary image payloads' {
            InModuleScope ToastSql {
                { Resolve-ToastImageInput -ImageBytes ([byte[]]@()) -ContentType 'image/png' -ParameterName 'AppLogo' } |
                    Should -Throw '*empty array*'
            }
        }

        It 'rejects unsupported binary image content types' {
            InModuleScope ToastSql {
                { Resolve-ToastImageInput -ImageBytes ([byte[]](1,2,3)) -ContentType 'image/webp' -ParameterName 'HeroImage' } |
                    Should -Throw '*HeroImage content type is required and must be one of*'
            }
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

        It 'materializes binary image data to a temporary client file' {
            $row = [pscustomobject]@{
                MessageId = 42
                Title = 'Title'
                Body = 'Body'
                AppLogoBytes = [byte[]](137,80,78,71,13,10,26,10)
                AppLogoContentType = 'image/png'
            }

            $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','AppLogo')

            try {
                $result.Parameters.AppLogo | Should -Match 'BurnTtoast-SQLserver-'
                [System.IO.Path]::GetExtension($result.Parameters.AppLogo) | Should -Be '.png'
                (Test-Path -LiteralPath $result.Parameters.AppLogo) | Should -Be $true
                $result.TemporaryFiles.Count | Should -Be 1
            } finally {
                foreach ($temporaryFile in $result.TemporaryFiles) {
                    Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'prefers binary image payload over path when both are available' {
            $row = [pscustomobject]@{
                MessageId = 42
                Title = 'Title'
                Body = 'Body'
                AppLogoPath = 'C:\Toast\logo.png'
                AppLogoBytes = [byte[]](137,80,78,71,13,10,26,10)
                AppLogoContentType = 'image/png'
            }

            $result = Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','AppLogo')

            try {
                $result.Parameters.AppLogo | Should -Not -Be 'C:\Toast\logo.png'
                [System.IO.Path]::GetExtension($result.Parameters.AppLogo) | Should -Be '.png'
                (Test-Path -LiteralPath $result.Parameters.AppLogo) | Should -Be $true
                $result.TemporaryFiles.Count | Should -Be 1
            } finally {
                foreach ($temporaryFile in $result.TemporaryFiles) {
                    Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'rejects empty binary payloads even when a path is also present' {
            $row = [pscustomobject]@{
                MessageId = 42
                Title = 'Title'
                Body = 'Body'
                AppLogoPath = 'C:\Toast\logo.png'
                AppLogoBytes = [byte[]]@()
                AppLogoContentType = 'image/png'
            }

            { Get-ToastNotificationParameters -ToastRow $row -SupportedParameters @('Text','AppLogo') } |
                Should -Throw '*empty array*'
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
            $cmd = InModuleScope ToastSql {
                $moduleCmd = [System.Data.SqlClient.SqlCommand]::new()
                foreach ($name in @('GroupName','Title','Body','Sound','IsUrgent','RepeatIntervalSeconds','RepeatCount','ButtonText','ButtonArguments','ButtonActivationType','Scenario')) {
                    $value = switch ($name) {
                        'GroupName' { 'g' }
                        'Title' { 't' }
                        'Body' { 'b' }
                        'IsUrgent' { $false }
                        default { $null }
                    }

                    Add-ToastSqlParameter -Command $moduleCmd -Name $name -Value $value
                }

                $moduleCmd
            }

            $cmd.Parameters.Contains('@GroupName') | Should -Be $true
            $cmd.Parameters.Contains('@Title') | Should -Be $true
            $cmd.Parameters.Contains('@Body') | Should -Be $true
            $cmd.Parameters.Contains('@ButtonText') | Should -Be $true
            $cmd.Parameters.Contains('@Scenario') | Should -Be $true
        }

        It 'binds byte arrays as VarBinary max parameters' {
            $parameter = InModuleScope ToastSql {
                $moduleCmd = [System.Data.SqlClient.SqlCommand]::new()
                Add-ToastSqlParameter -Command $moduleCmd -Name 'AppLogoBytes' -Value ([byte[]](1,2,3,4))
                $moduleCmd.Parameters['@AppLogoBytes']
            }

            $parameter.SqlDbType | Should -Be ([System.Data.SqlDbType]::VarBinary)
            $parameter.Size | Should -Be -1
            ($parameter.Value -join ',') | Should -Be '1,2,3,4'
        }

        It 'preserves known SQL types when null values are bound' {
            $result = InModuleScope ToastSql {
                $moduleCmd = [System.Data.SqlClient.SqlCommand]::new()
                Add-ToastSqlParameter -Command $moduleCmd -Name 'AppLogoBytes' -Value $null
                Add-ToastSqlParameter -Command $moduleCmd -Name 'ExpiresUtc' -Value $null
                Add-ToastSqlParameter -Command $moduleCmd -Name 'RepeatCount' -Value $null

                [pscustomobject]@{
                    AppLogoBytes = $moduleCmd.Parameters['@AppLogoBytes']
                    ExpiresUtc = $moduleCmd.Parameters['@ExpiresUtc']
                    RepeatCount = $moduleCmd.Parameters['@RepeatCount']
                }
            }

            $result.AppLogoBytes.SqlDbType | Should -Be ([System.Data.SqlDbType]::VarBinary)
            $result.AppLogoBytes.Size | Should -Be -1
            $result.ExpiresUtc.SqlDbType | Should -Be ([System.Data.SqlDbType]::DateTime2)
            $result.RepeatCount.SqlDbType | Should -Be ([System.Data.SqlDbType]::Int)
        }
    }

    Context 'toast notification cleanup' {
        It 'removes temporary binary image files after showing a toast' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param(
                        [string[]]$Text,
                        [string]$AppLogo
                    )

                    $script:capturedAppLogoPath = $AppLogo
                    Test-Path -LiteralPath $AppLogo | Should -Be $true
                }

                try {
                    $script:capturedAppLogoPath = $null
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        AppLogoBytes = [byte[]](137,80,78,71,13,10,26,10)
                        AppLogoContentType = 'image/png'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','AppLogo')

                    $script:capturedAppLogoPath | Should -Not -BeNullOrEmpty
                    (Test-Path -LiteralPath $script:capturedAppLogoPath) | Should -Be $false
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    if ($script:capturedAppLogoPath) {
                        Remove-Item -LiteralPath $script:capturedAppLogoPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        It 'removes temporary binary image files when BurntToast throws' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param(
                        [string[]]$Text,
                        [string]$AppLogo
                    )

                    $script:capturedFailureAppLogoPath = $AppLogo
                    throw 'boom'
                }

                try {
                    $script:capturedFailureAppLogoPath = $null
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        AppLogoBytes = [byte[]](137,80,78,71,13,10,26,10)
                        AppLogoContentType = 'image/png'
                    }

                    { Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','AppLogo') } | Should -Throw 'boom'

                    $script:capturedFailureAppLogoPath | Should -Not -BeNullOrEmpty
                    (Test-Path -LiteralPath $script:capturedFailureAppLogoPath) | Should -Be $false
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    if ($script:capturedFailureAppLogoPath) {
                        Remove-Item -LiteralPath $script:capturedFailureAppLogoPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    Context 'persistent scenario rendering' {
        It 'passes scenario directly when New-BurntToastNotification supports it' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param(
                        [string[]]$Text,
                        [string]$AppLogo,
                        [string]$HeroImage,
                        [string]$Sound,
                        [switch]$Urgent,
                        [string]$Scenario
                    )
                }

                Mock New-BurntToastNotification {
                    param(
                        [string[]]$Text,
                        [string]$AppLogo,
                        [string]$HeroImage,
                        [string]$Sound,
                        [switch]$Urgent,
                        [string]$Scenario
                    )
                }

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        AppLogoPath = 'C:\Toast\logo.png'
                        HeroImagePath = 'C:\Toast\hero.png'
                        Sound = 'Reminder'
                        IsUrgent = $true
                        Scenario = 'Reminder'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','AppLogo','HeroImage','Sound','Urgent','Scenario')

                    Should -Invoke New-BurntToastNotification -Times 1 -ParameterFilter {
                        $Scenario -eq 'Reminder' -and
                        $AppLogo -eq 'C:\Toast\logo.png' -and
                        $HeroImage -eq 'C:\Toast\hero.png' -and
                        $Sound -eq 'Reminder' -and
                        $Urgent
                    }
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                }
            }
        }

        It 'uses New-BTContent and Submit-BTNotification when scenario support requires low-level commands' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param(
                        [string[]]$Text
                    )
                }

                function New-BTText {
                    param([string]$Text)
                }

                function New-BTBinding {
                    param([object[]]$Children)
                }

                function New-BTVisual {
                    param($BindingGeneric)
                }

                function New-BTContent {
                    param(
                        $Visual,
                        [string]$Scenario
                    )
                }

                function Submit-BTNotification {
                    param($Content)
                }

                Mock New-BurntToastNotification {}
                Mock New-BTText { [pscustomobject]@{ Text = $Text } }
                Mock New-BTBinding { [pscustomobject]@{ Children = $Children } }
                Mock New-BTVisual { [pscustomobject]@{ Binding = $BindingGeneric } }
                Mock New-BTContent { [pscustomobject]@{ Scenario = $Scenario } }
                Mock Submit-BTNotification {}

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        Scenario = 'Reminder'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','Scenario')

                    Should -Invoke New-BurntToastNotification -Times 0
                    Should -Invoke New-BTContent -Times 1 -ParameterFilter { $Scenario -eq 'Reminder' }
                    Should -Invoke Submit-BTNotification -Times 1
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTText -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTBinding -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTVisual -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTContent -ErrorAction SilentlyContinue
                    Remove-Item Function:\Submit-BTNotification -ErrorAction SilentlyContinue
                }
            }
        }

        It 'falls back and warns when BurntToast lacks persistent scenario support' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param(
                        [string[]]$Text
                    )
                }

                function New-BTText {
                    param([string]$Text)
                }

                function New-BTBinding {
                    param([object[]]$Children)
                }

                function New-BTVisual {
                    param($BindingGeneric)
                }

                function New-BTContent {
                    param($Visual)
                }

                function Submit-BTNotification {
                    param($Content)
                }

                Mock New-BurntToastNotification {}
                Mock New-BTText { [pscustomobject]@{ Text = $Text } }
                Mock New-BTBinding { [pscustomobject]@{ Children = $Children } }
                Mock New-BTVisual { [pscustomobject]@{ Binding = $BindingGeneric } }
                Mock New-BTContent { [pscustomobject]@{ Visual = $Visual } }
                Mock Submit-BTNotification {}
                Mock Write-Warning {}

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        Scenario = 'Reminder'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','Scenario')

                    Should -Invoke New-BurntToastNotification -Times 1
                    Should -Invoke Submit-BTNotification -Times 0
                    Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'does not support persistent toast scenario' }
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTText -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTBinding -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTVisual -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTContent -ErrorAction SilentlyContinue
                    Remove-Item Function:\Submit-BTNotification -ErrorAction SilentlyContinue
                }
            }
        }

        It 'warns but still submits when low-level scenario rendering lacks sound support' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param(
                        [string[]]$Text
                    )
                }

                function New-BTText {
                    param([string]$Text)
                }

                function New-BTBinding {
                    param([object[]]$Children)
                }

                function New-BTVisual {
                    param($BindingGeneric)
                }

                function New-BTContent {
                    param(
                        $Visual,
                        [string]$Scenario,
                        $Audio
                    )
                }

                function Submit-BTNotification {
                    param($Content)
                }

                Mock New-BurntToastNotification {}
                Mock New-BTText { [pscustomobject]@{ Text = $Text } }
                Mock New-BTBinding { [pscustomobject]@{ Children = $Children } }
                Mock New-BTVisual { [pscustomobject]@{ Binding = $BindingGeneric } }
                Mock New-BTContent { [pscustomobject]@{ Scenario = $Scenario; Audio = $Audio } }
                Mock Submit-BTNotification {}
                Mock Write-Warning {}

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        Sound = 'Reminder'
                        Scenario = 'Reminder'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','Sound','Scenario')

                    Should -Invoke New-BurntToastNotification -Times 0
                    Should -Invoke Submit-BTNotification -Times 1
                    Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'without custom sound' }
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTText -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTBinding -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTVisual -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTContent -ErrorAction SilentlyContinue
                    Remove-Item Function:\Submit-BTNotification -ErrorAction SilentlyContinue
                }
            }
        }

        It 'maps supported low-level sound values to New-BTAudio source URIs' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param([string[]]$Text)
                }

                function New-BTText { param([string]$Text) }
                function New-BTBinding { param([object[]]$Children) }
                function New-BTVisual { param($BindingGeneric) }
                function New-BTContent {
                    param(
                        $Visual,
                        [string]$Scenario,
                        $Audio
                    )
                }
                function New-BTAudio {
                    param([string]$Source)
                }
                function Submit-BTNotification { param($Content) }

                Mock New-BurntToastNotification {}
                Mock New-BTText { [pscustomobject]@{ Text = $Text } }
                Mock New-BTBinding { [pscustomobject]@{ Children = $Children } }
                Mock New-BTVisual { [pscustomobject]@{ Binding = $BindingGeneric } }
                Mock New-BTAudio { [pscustomobject]@{ Source = $Source } }
                Mock New-BTContent { [pscustomobject]@{ Scenario = $Scenario; Audio = $Audio } }
                Mock Submit-BTNotification {}
                Mock Write-Warning {}

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        Sound = 'Reminder'
                        Scenario = 'Reminder'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','Sound','Scenario')

                    Should -Invoke New-BTAudio -Times 1 -ParameterFilter { $Source -eq 'ms-winsoundevent:Notification.Reminder' }
                    Should -Invoke New-BTContent -Times 1 -ParameterFilter { $Audio.Source -eq 'ms-winsoundevent:Notification.Reminder' }
                    Should -Invoke Submit-BTNotification -Times 1
                    Should -Invoke Write-Warning -Times 0
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTText -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTBinding -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTVisual -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTContent -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTAudio -ErrorAction SilentlyContinue
                    Remove-Item Function:\Submit-BTNotification -ErrorAction SilentlyContinue
                }
            }
        }

        It 'preserves silent sound semantics for low-level scenario rendering when supported' {
            InModuleScope ToastSql {
                function New-BurntToastNotification {
                    param([string[]]$Text)
                }

                function New-BTText { param([string]$Text) }
                function New-BTBinding { param([object[]]$Children) }
                function New-BTVisual { param($BindingGeneric) }
                function New-BTContent {
                    param(
                        $Visual,
                        [string]$Scenario,
                        $Audio
                    )
                }
                function New-BTAudio {
                    param([switch]$Silent)
                }
                function Submit-BTNotification { param($Content) }

                Mock New-BurntToastNotification {}
                Mock New-BTText { [pscustomobject]@{ Text = $Text } }
                Mock New-BTBinding { [pscustomobject]@{ Children = $Children } }
                Mock New-BTVisual { [pscustomobject]@{ Binding = $BindingGeneric } }
                Mock New-BTAudio { [pscustomobject]@{ Silent = $Silent } }
                Mock New-BTContent { [pscustomobject]@{ Scenario = $Scenario; Audio = $Audio } }
                Mock Submit-BTNotification {}
                Mock Write-Warning {}

                try {
                    $row = [pscustomobject]@{
                        MessageId = 42
                        Title = 'Title'
                        Body = 'Body'
                        Sound = 'Silent'
                        Scenario = 'Reminder'
                    }

                    Invoke-ToastNotification -ToastRow $row -SupportedParameters @('Text','Sound','Scenario')

                    Should -Invoke New-BTAudio -Times 1 -ParameterFilter { $Silent }
                    Should -Invoke Submit-BTNotification -Times 1
                    Should -Invoke Write-Warning -Times 0
                } finally {
                    Remove-Item Function:\New-BurntToastNotification -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTText -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTBinding -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTVisual -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTContent -ErrorAction SilentlyContinue
                    Remove-Item Function:\New-BTAudio -ErrorAction SilentlyContinue
                    Remove-Item Function:\Submit-BTNotification -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'local-time reporting SQL compatibility' {
        It 'keeps @TimeZoneName and avoids UTC-to-local conversion assumptions' {
            $scriptPath = Join-Path $PSScriptRoot '..\sql\004-local-time-reporting.sql'
            $scriptText = Get-Content -Path $scriptPath -Raw

            $scriptText | Should -Match "DECLARE @DefaultLocalTimeZone sysname = NULL;"
            $scriptText | Should -Match "CURRENT_TIMEZONE\(\)"
            $scriptText | Should -Match "FROM sys\.time_zone_info"
            $scriptText | Should -Match "ufn_ToastMessageLocal\s*\(\s*@TimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''',\s*@ServerTimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N'''"
            $scriptText | Should -Match "ufn_ToastDeliveryLocal\s*\(\s*@TimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''',\s*@ServerTimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N'''"
            $scriptText | Should -Match "\(m\.CreatedUtc AT TIME ZONE @ServerTimeZoneName\) AT TIME ZONE @TimeZoneName"
            $scriptText | Should -Match "\(d\.LastAttemptUtc AT TIME ZONE @ServerTimeZoneName\) AT TIME ZONE @TimeZoneName"
            $scriptText | Should -Match "m\.CreatedUtc AT TIME ZONE N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''' AS CreatedLocalTime"
            $scriptText | Should -Match "d\.LastAttemptUtc AT TIME ZONE N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''' AS LastAttemptLocalTime"
            $scriptText | Should -Match "m\.CreatedUtc AS CreatedServerLocalTime"
            $scriptText | Should -Match "d\.LastAttemptUtc AS LastAttemptServerLocalTime"
            $scriptText | Should -Not -Match "AT TIME ZONE ''UTC''"
        }
    }

    Context 'legacy UTC migration SQL coverage' {
        It 'converts legacy UTC timestamp columns when upgrading existing installations' {
            $scriptPath = Join-Path $PSScriptRoot '..\sql\002-toast-design-repeat.sql'
            $scriptText = Get-Content -Path $scriptPath -Raw

            $scriptText | Should -Match "CURRENT_TIMEZONE\(\)"
            $scriptText | Should -Match "FROM sys\.time_zone_info"
            $scriptText | Should -Match "UPDATE dbo\.ToastMessage"
            $scriptText | Should -Match "UPDATE dbo\.ToastDelivery"
            $scriptText | Should -Match "UPDATE dbo\.ToastClient"
            $scriptText | Should -Match "AT TIME ZONE 'UTC'\) AT TIME ZONE @ServerLocalTimeZone"
            $scriptText | Should -Match "DECLARE @DropNextShowUtcDefaultConstraintSql nvarchar\(max\)"
            $scriptText | Should -Match "SET @DropNextShowUtcDefaultConstraintSql =\s*N'ALTER TABLE dbo\.ToastDelivery DROP CONSTRAINT '\s*\+\s*QUOTENAME\(@NextShowUtcDefaultConstraintName\)\s*\+\s*N';'"
            $scriptText | Should -Match "EXEC sp_executesql @DropNextShowUtcDefaultConstraintSql"
        }
    }

    Context 'queued-toast SQL procedure compatibility' {
        It 'exposes queue/get/record contracts expected by the client scripts' {
            $repeatScriptPath = Join-Path $PSScriptRoot '..\sql\002-toast-design-repeat.sql'
            $buttonScriptPath = Join-Path $PSScriptRoot '..\sql\003-toast-button.sql'
            $repeatScriptText = Get-Content -Path $repeatScriptPath -Raw
            $buttonScriptText = Get-Content -Path $buttonScriptPath -Raw

            $repeatScriptText | Should -Match "CREATE OR ALTER PROCEDURE dbo\.usp_RecordToastDelivery"
            $repeatScriptText | Should -Match "@LeaseId uniqueidentifier"
            $repeatScriptText | Should -Match "inserted\.LeaseId"
            $repeatScriptText | Should -Match "inserted\.ShowCount"
            $repeatScriptText | Should -Match "@AppLogoBytes varbinary\(max\) = NULL"
            $repeatScriptText | Should -Match "@AppLogoContentType varchar\(100\) = NULL"
            $repeatScriptText | Should -Match "@HeroImageBytes varbinary\(max\) = NULL"
            $repeatScriptText | Should -Match "@HeroImageContentType varchar\(100\) = NULL"

            $buttonScriptText | Should -Match "@AppLogoPath nvarchar\(1024\) = NULL"
            $buttonScriptText | Should -Match "@HeroImagePath nvarchar\(1024\) = NULL"
            $buttonScriptText | Should -Match "@AppLogoBytes varbinary\(max\) = NULL"
            $buttonScriptText | Should -Match "@AppLogoContentType varchar\(100\) = NULL"
            $buttonScriptText | Should -Match "@HeroImageBytes varbinary\(max\) = NULL"
            $buttonScriptText | Should -Match "@HeroImageContentType varchar\(100\) = NULL"
            $buttonScriptText | Should -Match "@Sound varchar\(20\) = NULL"
            $buttonScriptText | Should -Match "@IsUrgent bit = 0"
            $buttonScriptText | Should -Match "@RepeatIntervalSeconds int = NULL"
            $buttonScriptText | Should -Match "@RepeatCount int = NULL"
            $buttonScriptText | Should -Match "@ButtonText nvarchar\(200\) = NULL"
            $buttonScriptText | Should -Match "@ButtonArguments nvarchar\(2048\) = NULL"
            $buttonScriptText | Should -Match "@ButtonActivationType varchar\(20\) = NULL"
            $buttonScriptText | Should -Match "@Scenario varchar\(20\) = 'Default'"
            $buttonScriptText | Should -Match "Scenario must be Default, Reminder, Alarm, or IncomingCall"
            $buttonScriptText | Should -Match "m\.Scenario"
            $buttonScriptText | Should -Match "m\.AppLogoBytes"
            $buttonScriptText | Should -Match "m\.HeroImageBytes"
        }
    }
}
