#requires -Version 5.1
<#
Dhone lab lifecycle controller v1.1 for the existing Windows Docker Desktop lab.
Examples (run in a regular Windows PowerShell window):
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Dhone-Lab.ps1 Start
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Dhone-Lab.ps1 Start -WithApi
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Dhone-Lab.ps1 Status
  powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Dhone-Lab.ps1 Stop

Manages existing pingdirectory/pingfederate and, when present, pingaccess.
Docker context: desktop-linux.
Start order: PingDirectory -> PingFederate -> optional PingAccess -> optional API.
Each container must become healthy before the next starts.
Stop order: API -> optional PingAccess -> PingFederate -> PingDirectory.
No recreate, compose down, rm, prune, volume deletion, restart-policy changes,
Windows shutdown or WSL shutdown. Docker Desktop remains running after Stop.
Docker stop --timeout -1 waits for graceful exit, without a timed force-kill.
If a container hangs, inspect it separately; this script does not force-kill it.
API control requires the accompanying updated Dhone-Protected-API.ps1.
The API PowerShell window may remain open after the API exits.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('Start','Stop','Status')][string]$Action = 'Status',
    [switch]$WithApi,
    [ValidateRange(30,900)][int]$EngineTimeoutSeconds = 180,
    [ValidateRange(30,900)][int]$HealthTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
$script:labContext = 'desktop-linux'
$script:dockerPath = $null
$apiPath = Join-Path $PSScriptRoot 'Dhone-Protected-API.ps1'
$apiStopFile = Join-Path $PSScriptRoot 'Dhone-API.stop'

function Invoke-LabDocker([string[]]$Arguments, [switch]$AllowFailure) {
    # Capture native stderr without letting PowerShell 5.1 stop a readiness poll.
    $ErrorActionPreference = 'Continue'
    $lines = @(& $script:dockerPath --context $script:labContext @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("Docker {0} failed: {1}" -f $Arguments[0],($lines -join ' '))
    }
    return [pscustomobject]@{Code=$code; Lines=$lines}
}

function Test-LinuxEngine {
    $result = Invoke-LabDocker -Arguments @('info','--format','{{.OSType}}') -AllowFailure
    return ($result.Code -eq 0 -and $result.Lines -contains 'linux')
}

function Get-LabStartOrder {
    $result = Invoke-LabDocker -Arguments @('ps','--all','--format','{{.Names}}')
    $names = @($result.Lines)
    foreach ($required in @('pingdirectory','pingfederate')) {
        if ($names -notcontains $required) {
            throw "Required existing container '$required' is missing. No replacement will be created."
        }
    }
    'pingdirectory'
    'pingfederate'
    if ($names -contains 'pingaccess') { 'pingaccess' }
}

function Get-LabContainer([string]$Name) {
    $format = '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
    $result = Invoke-LabDocker -Arguments @('inspect','--type','container','--format',$format,$Name) -AllowFailure
    if ($result.Code -ne 0) { throw "Existing container '$Name' could not be inspected. No replacement will be created." }
    $value = @($result.Lines | Where-Object { $_ -match '^[a-z]+\|[a-z]+$' })
    if ($value.Count -ne 1) { throw "Unexpected state response for '$Name'." }
    $parts = $value[0].Split('|')
    return [pscustomobject]@{Container=$Name; State=$parts[0]; Health=$parts[1]}
}

function Wait-ContainerHealthy([string]$Name) {
    Write-Host "Waiting for $Name to become healthy..."
    $deadline = [datetime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
    do {
        $state = Get-LabContainer $Name
        if ($state.State -eq 'running' -and $state.Health -eq 'healthy') {
            Write-Host "$Name is healthy." -ForegroundColor Green
            return
        }
        if ($state.State -in @('exited','dead') -or $state.Health -in @('unhealthy','none')) {
            throw ("{0}: state={1}, health={2}. Inspect its logs before continuing." -f $Name,$state.State,$state.Health)
        }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    throw "$Name did not become healthy within $HealthTimeoutSeconds seconds. The container was left intact."
}

function Test-ApiPort {
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return (@($listeners | Where-Object { $_.Port -eq 8766 }).Count -gt 0)
}

function Test-DhoneApi {
    $ErrorActionPreference = 'SilentlyContinue'
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $curl) { return $false }
    $raw = @(& $curl.Source '--disable' '--silent' '--max-time' '2' '--noproxy' '127.0.0.1' 'http://127.0.0.1:8766/lab/data' 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    try {
        $body = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
        return ($body.api -ceq 'dhone-lab-v1' -and $body.reason -ceq 'missing_token')
    } catch { return $false }
}

function Start-LabApi {
    if (Test-ApiPort) {
        if (Test-DhoneApi) { Write-Host 'Dhone API is already running.'; return }
        throw 'Port 8766 is occupied by an unrecognized service. It was not changed.'
    }
    if (-not (Test-Path -LiteralPath $apiPath -PathType Leaf)) { throw "API script missing: $apiPath" }
    Write-Host 'Opening the API in a separate PowerShell window...'
    $quotedPath = '"' + $apiPath + '"'
    $apiProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList @('-NoLogo','-NoProfile','-NoExit','-ExecutionPolicy','RemoteSigned','-File',$quotedPath) `
        -WorkingDirectory $PSScriptRoot -PassThru
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    do {
        if (Test-DhoneApi) { Write-Host 'Dhone API is ready.' -ForegroundColor Green; return }
        $apiProcess.Refresh()
        if ($apiProcess.HasExited) { throw 'The API process exited before becoming ready. Inspect its startup error.' }
        Start-Sleep -Seconds 1
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'The API did not become ready. Read the error in its PowerShell window; PF and PD remain available.'
}

function Stop-LabApi {
    if (-not (Test-ApiPort)) { Write-Host 'API is already stopped.'; return }
    if (-not (Test-DhoneApi)) {
        throw 'Port 8766 is occupied by an unrecognized service. Close the intended API manually before stopping the lab.'
    }
    Write-Host 'Requesting a graceful API stop...'
    [IO.File]::WriteAllText($apiStopFile, [datetime]::UtcNow.ToString('o'))
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    do {
        if (-not (Test-ApiPort)) { Write-Host 'API stopped.' -ForegroundColor Green; return }
        Start-Sleep -Milliseconds 250
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'API stop was not acknowledged. Press Ctrl+C in the API window, then rerun Stop. Use the updated API script.'
}

try {
    Write-Host 'Dhone lab controller v1.1'
    if ($WithApi -and $Action -ne 'Start') { throw '-WithApi applies only to Start.' }
    $script:dockerPath = (Get-Command docker.exe -CommandType Application -ErrorAction Stop).Source
    $context = Invoke-LabDocker -Arguments @('context','inspect',$script:labContext,'--format','{{.Endpoints.docker.Host}}')
    $endpoint = [string]$context.Lines[-1]
    if (-not $endpoint.StartsWith('npipe:////./pipe/', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'desktop-linux is not a local Docker Desktop named-pipe context. No containers were changed.'
    }

    if ($Action -eq 'Start') {
        if (-not (Test-LinuxEngine)) {
            Write-Host 'Starting Docker Desktop...'
            $null = Invoke-LabDocker -Arguments @('desktop','start','--timeout',[string]$EngineTimeoutSeconds)
            $deadline = [datetime]::UtcNow.AddSeconds($EngineTimeoutSeconds)
            while (-not (Test-LinuxEngine)) {
                if ([datetime]::UtcNow -ge $deadline) { throw 'Linux Docker engine is unavailable. Open Docker Desktop and confirm Linux containers are selected.' }
                Start-Sleep -Seconds 2
            }
        }
        # Inspect every selected container before changing any container.
        $startOrder = @(Get-LabStartOrder)
        foreach ($name in $startOrder) { $null = Get-LabContainer $name }
        foreach ($name in $startOrder) {
            $state = Get-LabContainer $name
            if ($state.State -eq 'paused') { $null = Invoke-LabDocker -Arguments @('unpause',$name) }
            elseif ($state.State -notin @('running','restarting')) {
                Write-Host "Starting $name..."
                $null = Invoke-LabDocker -Arguments @('start',$name)
            }
            Wait-ContainerHealthy $name
        }
        if ($WithApi) { Start-LabApi }
        Write-Host 'Lab startup complete.' -ForegroundColor Green
        Write-Host 'PF admin: https://localhost:9999  |  PF runtime: https://localhost:9031'
        if ($startOrder -contains 'pingaccess') { Write-Host 'PA admin: https://localhost:9000  |  PA engine port: 3000' }
    } elseif ($Action -eq 'Stop') {
        Stop-LabApi
        if (-not (Test-LinuxEngine)) { throw 'Docker engine is unavailable; container shutdown could not be verified. Open Docker Desktop and rerun Stop.' }
        $stopOrder = @(Get-LabStartOrder)
        [array]::Reverse($stopOrder)
        foreach ($name in $stopOrder) { $null = Get-LabContainer $name }
        foreach ($name in $stopOrder) {
            $state = Get-LabContainer $name
            if ($state.State -in @('exited','created')) { Write-Host "$name is already stopped."; continue }
            if ($state.State -eq 'paused') { $null = Invoke-LabDocker -Arguments @('unpause',$name) }
            Write-Host "Stopping $name; waiting for graceful exit..."
            $null = Invoke-LabDocker -Arguments @('stop','--timeout','-1',$name)
            $state = Get-LabContainer $name
            if ($state.State -ne 'exited') { throw "$name has not reached the stopped state." }
        }
        Write-Host 'Lab shutdown complete. Docker Desktop remains open.' -ForegroundColor Green
    } else {
        if (Test-LinuxEngine) {
            @(foreach ($name in @(Get-LabStartOrder)) { Get-LabContainer $name }) | Format-Table -AutoSize
        } else { Write-Host 'Docker Linux engine: unavailable (container state cannot be verified).' }
        if (Test-DhoneApi) { Write-Host 'Dhone API: running on 127.0.0.1:8766' }
        elseif (Test-ApiPort) { Write-Host 'API port 8766: occupied by an unrecognized service.' }
        else { Write-Host 'Dhone API: stopped' }
    }
} catch {
    Write-Host ('FAIL: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
