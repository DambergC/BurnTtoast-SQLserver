[CmdletBinding()]
param([string]$TaskName='BurntToast SQL Client',[Parameter(Mandatory)][string]$ScriptPath,[Parameter(Mandatory)][string]$ConfigPath)
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -PollSeconds 30"
$trigger=New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description 'Displays SQL-backed BurntToast, WPF, or AppDeployToolkit notifications in the interactive user session.' -Force
