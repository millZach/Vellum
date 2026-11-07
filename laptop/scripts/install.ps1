<#
.SYNOPSIS
Installs Vellum's laptop indexer for this Windows user and starts it at every logon.

.DESCRIPTION
Makes a Python virtual environment in %LOCALAPPDATA%\Vellum\indexer\venv, installs the indexer into it with the
pinned dependencies in requirements.lock, and registers the scheduled task "\Vellum\Vellum laptop indexer", which
runs it (pythonw, no window) at logon, at below-normal priority, on battery too, and restarts it if it stops. It
then starts the task, unless -NoStart.

Nothing is written to Dropbox here. The indexer itself writes only to Dropbox\Vellum\Index; its state file, log
and settings stay in %LOCALAPPDATA%\Vellum\indexer.

.PARAMETER DropboxPath
The Dropbox folder, when Dropbox's info.json should not be used. Written to settings.toml.

.PARAMETER DropboxAppKey
Vellum's Dropbox app key (docs/dropbox.md), kept in settings.toml on this laptop only. With it the installer signs
the laptop in to Dropbox (a page to open and a code to paste), so online-only files can be downloaded to the scratch
folder, read and deleted. The token goes to Windows Credential Manager.

.PARAMETER ScratchPath
Where online-only files are downloaded to be read, then deleted. D:\Vellum indexer\scratch by default.

.PARAMETER Python
The Python 3.12 or newer to build the environment with. By default the py launcher's newest Python 3, else python.

.PARAMETER NoStart
Register the task without starting it now.
#>
param(
    [string]$DropboxPath,
    [string]$DropboxAppKey,
    [string]$ScratchPath,
    [string]$Python,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'

$laptop = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$indexerHome = Join-Path $env:LOCALAPPDATA 'Vellum\indexer'
$venv = Join-Path $indexerHome 'venv'
$taskName = 'Vellum laptop indexer'
$taskPath = '\Vellum\'

function Find-Python {
    if ($Python) { return , @($Python) }
    if (Get-Command py -ErrorAction SilentlyContinue) { return , @('py', '-3') }
    if (Get-Command python -ErrorAction SilentlyContinue) { return , @('python') }
    throw 'No Python found. Install Python 3.12 or newer from python.org, or pass -Python.'
}

$py = Find-Python
$pyExe = $py[0]
$pyArgs = @($py | Select-Object -Skip 1)
& $pyExe @pyArgs -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'
if ($LASTEXITCODE -ne 0) { throw "$($py -join ' ') is older than Python 3.12." }

New-Item -ItemType Directory -Force -Path $indexerHome | Out-Null
if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
    Write-Host "Making the environment in $venv"
    & $pyExe @pyArgs -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Could not make the virtual environment.' }
}
$venvPython = Join-Path $venv 'Scripts\python.exe'
$venvPythonw = Join-Path $venv 'Scripts\pythonw.exe'

Write-Host 'Installing the indexer and its pinned dependencies'
& $venvPython -m pip install --disable-pip-version-check --quiet --requirement (Join-Path $laptop 'requirements.lock')
if ($LASTEXITCODE -ne 0) { throw 'pip could not install the dependencies.' }
& $venvPython -m pip install --disable-pip-version-check --quiet --no-deps --upgrade $laptop
if ($LASTEXITCODE -ne 0) { throw 'pip could not install the indexer.' }

$settingsFile = Join-Path $indexerHome 'settings.toml'
# Sets one top-level key in settings.toml, keeping every other line.
function Set-Setting([string]$Name, [string]$Value) {
    $line = "$Name = '" + $Value + "'"
    $kept = @()
    if (Test-Path $settingsFile) {
        $kept = @(Get-Content $settingsFile | Where-Object { $_ -notmatch "^\s*$Name\s*=" })
    }
    Set-Content -Path $settingsFile -Value (@($line) + $kept) -Encoding utf8
}
if ($DropboxPath) { Set-Setting 'dropbox_path' $DropboxPath }
if ($DropboxAppKey) { Set-Setting 'dropbox_app_key' $DropboxAppKey }
if ($ScratchPath) { Set-Setting 'scratch_folder' $ScratchPath }

# Fails here, before the task is registered, if no Dropbox folder can be found.
& $venvPython -m vellum_indexer where
if ($LASTEXITCODE -ne 0) { throw 'The indexer could not find the Dropbox folder. Pass -DropboxPath.' }

if ($DropboxAppKey) {
    # PKCE with no app secret: Dropbox shows a code to paste. Nothing about the token is printed.
    & $venvPython -m vellum_indexer sign-in
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Not signed in: online-only files stay unread until vellum-indexer sign-in.' }
}

$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $venvPythonw -Argument '-m vellum_indexer run' -WorkingDirectory $indexerHome
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -Priority 7
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Keeps Vellum's drawing index in Dropbox\Vellum\Index. Installed from $laptop." `
    -Force | Out-Null
Write-Host "Registered the task $taskPath$taskName to start at logon for $user"

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath
    Write-Host "Started it. The log is $(Join-Path $indexerHome 'indexer.log')"
}
