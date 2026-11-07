<#
.SYNOPSIS
Stops Vellum's laptop indexer and removes its logon task and environment.

.DESCRIPTION
Stops and unregisters the scheduled task "\Vellum\Vellum laptop indexer", stops any indexer still running from its
environment, and deletes %LOCALAPPDATA%\Vellum\indexer\venv. The state file, log and settings stay unless -Purge.
The index in Dropbox\Vellum\Index is left as it is; delete that folder by hand if the Duo should stop seeing it.

.PARAMETER Purge
Also sign out of Dropbox (the token leaves Windows Credential Manager and Dropbox is asked to end the sign-in) and
delete the state file, log and settings (all of %LOCALAPPDATA%\Vellum\indexer). The scratch folder on D: holds
nothing between files and is left.
#>
param([switch]$Purge)
$ErrorActionPreference = 'Stop'

$indexerHome = Join-Path $env:LOCALAPPDATA 'Vellum\indexer'
$venv = Join-Path $indexerHome 'venv'
$taskName = 'Vellum laptop indexer'
$taskPath = '\Vellum\'

$task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    Write-Host "Removed the task $taskPath$taskName"
} else {
    Write-Host 'No logon task was registered'
}

$running = Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($venv, [StringComparison]::OrdinalIgnoreCase) }
foreach ($p in $running) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped the indexer (process $($p.ProcessId))"
}
Start-Sleep -Milliseconds 500

$venvPython = Join-Path $venv 'Scripts\python.exe'
if ($Purge -and (Test-Path $venvPython)) {
    & $venvPython -m vellum_indexer sign-out
}

if (Test-Path $venv) {
    Remove-Item -Recurse -Force $venv
    Write-Host "Deleted $venv"
}
if ($Purge -and (Test-Path $indexerHome)) {
    Remove-Item -Recurse -Force $indexerHome
    Write-Host "Deleted $indexerHome (state, log and settings)"
}
