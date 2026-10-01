#requires -Version 5.1
<#
.SYNOPSIS
Creates the Dhone lab's standalone PingAccess 9.1 container.
.DESCRIPTION
Uses the official 2608-9.1.0 image, the user's original local license, a new
persistent volume, the existing identitylab network, and loopback-only ports.
Prompts locally for a new admin password. The password is passed through the
process environment, not command-line text or this script. Docker retains it
in the container environment; do not share full container inspection output.
Does not recreate or modify PingFederate, PingDirectory, or existing volumes.
Container health does not prove admin login or gateway authorization.
References:
https://developer.pingidentity.com/devops/how-to/existingLicense.html
https://developer.pingidentity.com/devops/docker-images/pingaccess/README.html
https://hub.docker.com/r/pingidentity/pingaccess/tags
#>
[CmdletBinding()]
param(
    [string]$LicensePath = '',
    [ValidateRange(180, 1800)][int]$StartupTimeoutSeconds = 600
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this on the Windows lab PC.' }
$script:PaDocker = (Get-Command docker.exe -ErrorAction Stop).Source
$paRoot = Join-Path $env:USERPROFILE 'DhoneLab\pingaccess'
$paImageTag = 'pingidentity/pingaccess:2608-9.1.0'
$paContainer = 'pingaccess'
$paVolume = 'dhone-pingaccess-data'
$paNetwork = 'identitylab'

function Invoke-PaDocker {
    param([Parameter(Mandatory=$true)][string[]]$DockerArgs, [switch]$ShowOutput)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $script:PaDocker --context desktop-linux @DockerArgs 2>&1 |
            ForEach-Object {
                $line = $_.ToString()
                if ($ShowOutput) { Write-Host $line }
                $line
            })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0) { throw ('Docker failed: ' + ($lines -join "`n")) }
    $lines
}

function Read-PaPasswordText {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $address = [IntPtr]::Zero
    try {
        $address = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($address)
    }
    finally {
        if ($address -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($address)
        }
        $secure.Dispose()
    }
}

Write-Host 'Dhone PingAccess installer v1.0'
Write-Host '[1/5] Checking the local engine, license file and unused resource names...'
$endpoint = (Invoke-PaDocker -DockerArgs @('context','inspect','desktop-linux','--format','{{.Endpoints.docker.Host}}')) -join ''
if (-not $endpoint.StartsWith('npipe:////./pipe/')) { throw 'desktop-linux must use a local Windows named pipe.' }
$engine = (Invoke-PaDocker -DockerArgs @('info','--format','{{.OSType}}')) -join ''
if ($engine.Trim() -ne 'linux') { throw 'Docker Desktop must run Linux containers.' }
$containers = @(Invoke-PaDocker -DockerArgs @('ps','-a','--format','{{.Names}}'))
if ($containers -contains $paContainer) { throw 'pingaccess already exists. Inspect its status; this installer will not replace it.' }
$volumes = @(Invoke-PaDocker -DockerArgs @('volume','ls','--format','{{.Name}}'))
if ($volumes -contains $paVolume) { throw 'dhone-pingaccess-data already exists. Keep it and review before retrying installation.' }
$networkDriver = (Invoke-PaDocker -DockerArgs @('network','inspect',$paNetwork,'--format','{{.Driver}}')) -join ''
if ($networkDriver.Trim() -ne 'bridge') { throw 'Expected the existing identitylab bridge network.' }

if ([string]::IsNullOrWhiteSpace($LicensePath)) {
    $licenseFolder = Join-Path $paRoot 'license'
    $candidates = @(Get-ChildItem -LiteralPath $licenseFolder -File | Where-Object {
        $_.Name -eq 'PingAccess-9.1-Development' -or $_.BaseName -eq 'PingAccess-9.1-Development'
    })
    if ($candidates.Count -ne 1) {
        throw 'Place the original PingAccess-9.1-Development license in DhoneLab\pingaccess\license, or provide -LicensePath with its full filename.'
    }
    $LicensePath = $candidates[0].FullName
}
$licenseItem = Get-Item -LiteralPath $LicensePath
if ($licenseItem.PSIsContainer -or $licenseItem.Length -eq 0) { throw 'LicensePath must be a nonempty file.' }
$LicensePath = $licenseItem.FullName
if ($LicensePath.Contains(',')) { throw 'Use a license file path without commas for Docker mounts.' }
$licenseText = [IO.File]::ReadAllText($LicensePath)
try {
    if ($licenseText -notmatch '(?m)^Product=PingAccess\s*$' -or
        $licenseText -notmatch '(?m)^Version=9\.1\s*$') {
        throw 'The local file does not identify PingAccess version 9.1. Use the original downloaded license.'
    }
    $expiryMatch = [regex]::Match($licenseText, '(?m)^ExpirationDate=(\d{4}-\d{2}-\d{2})\s*$')
    if (-not $expiryMatch.Success) { throw 'The license expiration date could not be read.' }
    $expiry = [DateTime]::ParseExact($expiryMatch.Groups[1].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if ($expiry.Date -lt (Get-Date).Date) { throw 'The license expiration date is in the past.' }
}
finally { $licenseText = $null }
$licenseHash = (Get-FileHash -LiteralPath $LicensePath -Algorithm SHA256).Hash
Write-Host ('License metadata: PingAccess 9.1, expires ' + $expiry.ToString('yyyy-MM-dd') + '. Product acceptance is checked during startup.')

Write-Host '[2/5] Pulling the official 2608-9.1.0 image (linux/amd64)...'
Invoke-PaDocker -DockerArgs @('pull','--platform','linux/amd64',$paImageTag) -ShowOutput | Out-Null
$paImageId = (Invoke-PaDocker -DockerArgs @('image','inspect',$paImageTag,'--format','{{.Id}}')) -join ''
$paImageId = $paImageId.Trim()
if ($paImageId -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Could not identify the pulled image.' }
$imageVersion = (Invoke-PaDocker -DockerArgs @('image','inspect',$paImageId,'--format','{{range .Config.Env}}{{println .}}{{end}}') |
    Where-Object { $_ -match '^PING_PRODUCT_VERSION=' }) -join ''
if ($imageVersion.Trim() -ne 'PING_PRODUCT_VERSION=9.1.0') { throw 'The pulled image does not report product version 9.1.0.' }

$paPassword = Read-PaPasswordText 'Choose a new PA Administrator password (14+ characters, upper/lowercase and a digit)'
$paConfirm = Read-PaPasswordText 'Confirm the new PA Administrator password'
if ($paPassword -cne $paConfirm -or $paPassword.Length -lt 14 -or
    $paPassword -cnotmatch '[A-Z]' -or $paPassword -cnotmatch '[a-z]' -or
    $paPassword -notmatch '[0-9]' -or $paPassword -match '[\r\n\x00]') {
    $paPassword = $null; $paConfirm = $null
    throw 'Passwords must match and meet the stated requirements. No PA container or volume was created.'
}
$paConfirm = $null
$previousPasswordEnv = [Environment]::GetEnvironmentVariable('PING_IDENTITY_PASSWORD','Process')
try {
    Write-Host '[3/5] Creating PingAccess with persistent data and local-only ports...'
    Invoke-PaDocker -DockerArgs @('volume','create','--label','dhone.lab.product=pingaccess',$paVolume) | Out-Null
    [Environment]::SetEnvironmentVariable('PING_IDENTITY_PASSWORD',$paPassword,'Process')
    Invoke-PaDocker -DockerArgs @(
        'run','--detach','--pull','never','--name',$paContainer,
        '--hostname','pa.dhone.in','--network',$paNetwork,'--network-alias','pa.dhone.in',
        '--restart','unless-stopped','--memory','3g','--cpus','2',
        '--publish','127.0.0.1:9000:9000','--publish','127.0.0.1:3000:3000',
        '--label','dhone.lab.product=pingaccess',
        '--mount',"type=volume,source=$paVolume,target=/opt/out",
        '--mount',"type=bind,source=$LicensePath,target=/opt/in/instance/conf/pingaccess.lic,readonly",
        '--env','PING_IDENTITY_ACCEPT_EULA=YES',
        '--env','PING_IDENTITY_PASSWORD',
        '--env','OPERATIONAL_MODE=STANDALONE',
        '--env','JAVA_RAM_PERCENTAGE=50.0',
        '--env','VERBOSE=false',
        $paImageId
    ) | Out-Null
}
finally {
    [Environment]::SetEnvironmentVariable('PING_IDENTITY_PASSWORD',$previousPasswordEnv,'Process')
    $paPassword = $null
}

Write-Host '[4/5] Waiting for PingAccess health...'
$watch = [Diagnostics.Stopwatch]::StartNew()
$previousStatus = ''
while ($true) {
    $state = ((Invoke-PaDocker -DockerArgs @('inspect','--format','{{json .State}}',$paContainer)) -join "`n") | ConvertFrom-Json
    $healthProperty = $state.PSObject.Properties['Health']
    $health = if ($null -ne $healthProperty) { [string]$state.Health.Status } else { 'not-configured' }
    $status = '{0} / {1}' -f $state.Status,$health
    if ($status -ne $previousStatus) { Write-Host "PingAccess: $status"; $previousStatus = $status }
    if ($state.Status -eq 'running' -and $health -eq 'healthy') { break }
    if ($state.Status -in @('exited','dead') -or $health -eq 'not-configured') {
        throw "PingAccess needs review: $status. Keep the container and volume; retrieve docker logs --tail 40 pingaccess."
    }
    if ($watch.Elapsed.TotalSeconds -ge $StartupTimeoutSeconds) {
        throw "PingAccess health timed out: $status. Keep its container and volume; retrieve docker logs --tail 40 pingaccess."
    }
    Write-Progress -Activity 'Starting Dhone PingAccess' -Status ("Elapsed: {0}s; {1}" -f [int]$watch.Elapsed.TotalSeconds,$status)
    Start-Sleep -Seconds 3
}
Write-Progress -Activity 'Starting Dhone PingAccess' -Completed

Write-Host '[5/5] Checking the installed license copy and recording the deployment...'
$installedHashLine = (Invoke-PaDocker -DockerArgs @('exec',$paContainer,'sha256sum','/opt/out/instance/conf/pingaccess.lic')) -join ''
$installedHash = ($installedHashLine.Trim() -split '\s+')[0]
if ($installedHash -ine $licenseHash) { throw 'The installed license copy does not match the local original. Keep both for review.' }
$deployment = [ordered]@{
    Container = $paContainer
    ImageTag = $paImageTag
    ImageId = $paImageId
    Volume = $paVolume
    Network = $paNetwork
    LicenseFileName = $licenseItem.Name
    LicenseExpires = $expiry.ToString('yyyy-MM-dd')
    AdminUrl = 'https://localhost:9000'
    EngineAddress = '127.0.0.1:3000'
}
$deploymentPath = Join-Path $paRoot 'deployment.json'
New-Item -ItemType Directory -Force -Path $paRoot | Out-Null
[IO.File]::WriteAllText($deploymentPath, ($deployment | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Result = 'READY'
    Container = $paContainer
    ProductVersion = '9.1.0'
    Health = $health
    PersistentVolume = $paVolume
    LicenseCopyMatches = $true
    AdminUrl = 'https://localhost:9000'
    AdminUser = 'Administrator'
    NextCheck = 'Admin certificate trust, console login and license acceptance'
} | Format-List
