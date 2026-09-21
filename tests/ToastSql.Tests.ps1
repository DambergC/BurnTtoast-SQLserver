Describe 'ToastSql module' {
    BeforeAll { Import-Module "$PSScriptRoot\..\src\Module\ToastSql.psm1" -Force }
    It 'builds an explicit TCP 1433 connection string' {
        $c=@{SqlServer='sql01';SqlPort=1433;SqlDatabase='ToastNotifications';UseIntegratedSecurity=$true;Encrypt=$true;TrustServerCertificate=$false;CommandTimeoutSeconds=15}
        Get-ToastConnectionString $c | Should -Match 'tcp:sql01,1433'
    }
    It 'rejects an unreachable SQL port' {
        Mock Test-NetConnection { $false }
        { Test-ToastSqlPort -Server 'invalid.example' -Port 1433 } | Should -Throw
    }
}
