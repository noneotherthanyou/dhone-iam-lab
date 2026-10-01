#requires -Version 5.1
<#
.SYNOPSIS
Restores the saved userRoot backup into an isolated, temporary PingDirectory.
.DESCRIPTION
Uses the exact local image ID in the saved container metadata. Imports the saved
encryption settings during fresh setup, performs an offline native restore, then
starts the recovered directory and checks required OUs and sample entries.
The backup is mounted read-only. A new named volume holds the recovered instance.
ResumeContainer reuses a stopped, labeled recovery copy after a completed restore.
No network or host ports are enabled. Successful runs remove their own temporary
container and volume. Failed runs keep the stopped copy for troubleshooting.
This tests userRoot data recovery, not a full PF/PD configuration restoration.
Revision 1.2-public: Parameterized backup and metadata paths.
Original 1.2 recovery logic retained; public path changes have not been rerun on Windows.
Official references:
https://docs.ping.directory/PingDirectory/latest/cli/setup.html
https://docs.ping.directory/PingDirectory/latest/cli/restore.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BackupPath,
    [string]$MetadataPath = '',
    [ValidateRange(300, 3600)][int]$TimeoutSeconds = 900,
    [string]$ResumeContainer = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script in Windows PowerShell on your lab PC.' }
$script:DhoneDockerPath = (Get-Command docker.exe -ErrorAction Stop).Source

function Invoke-DhoneDocker {
    param([Parameter(Mandatory = $true)][string[]]$DockerArgs)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $script:DhoneDockerPath --context desktop-linux @DockerArgs 2>&1)
        $dockerExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    $textLines = @($lines | ForEach-Object { $_.ToString() })
    if ($dockerExitCode -ne 0) {
        throw ('Docker command failed ({0}): {1}' -f $dockerExitCode, ($textLines -join "`n"))
    }
    $textLines
}

Write-Host 'Dhone PD restore test v1.2-public'
Write-Host '[1/5] Checking local Docker and saved recovery files...'
$endpoint = (Invoke-DhoneDocker -DockerArgs @(
    'context', 'inspect', 'desktop-linux', '--format', '{{.Endpoints.docker.Host}}'
)) -join ''
if (-not $endpoint.StartsWith('npipe:////./pipe/')) {
    throw 'desktop-linux must use a local Windows named pipe. No recovery resources were created.'
}
$engineType = (Invoke-DhoneDocker -DockerArgs @('info', '--format', '{{.OSType}}')) -join ''
if ($engineType.Trim() -ne 'linux') { throw 'Docker Desktop must be running Linux containers.' }

$backupItem = Get-Item -LiteralPath $BackupPath
if (-not $backupItem.PSIsContainer) { throw 'BackupPath must be a directory.' }
$BackupPath = $backupItem.FullName
if ($BackupPath.Contains(',')) { throw 'Use a local backup path without commas for Docker mounts.' }
if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
    $MetadataPath = Join-Path $BackupPath 'containers.json'
}
$metadataPath = (Get-Item -LiteralPath $MetadataPath -ErrorAction Stop).FullName
$requiredFiles = @(
    $metadataPath,
    (Join-Path $BackupPath 'PingDirectory.lic'),
    (Join-Path $BackupPath 'pd-secrets\root-password'),
    (Join-Path $BackupPath 'pd-secrets\encryption-password'),
    (Join-Path $BackupPath 'pingdirectory-native\encryption-settings.export'),
    (Join-Path $BackupPath 'pingdirectory-native\backends\userRoot\backup.info')
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing recovery file: $file" }
    if ((Get-Item -LiteralPath $file).Length -eq 0) { throw "Empty recovery file: $file" }
}
$savedContainers = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$savedPD = @($savedContainers | Where-Object { $_.Name -eq '/pingdirectory' })
if ($savedPD.Count -ne 1) { throw 'Saved metadata must identify exactly one pingdirectory container.' }
$pdImage = [string]$savedPD[0].Image
if ($pdImage -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Saved PD image ID is invalid.' }
$localImage = (Invoke-DhoneDocker -DockerArgs @('image', 'inspect', $pdImage, '--format', '{{.Id}}')) -join ''
if ($localImage.Trim() -ne $pdImage) { throw 'The exact saved PD image must already exist locally.' }

$runId = [guid]::NewGuid().ToString('N')
$containerName = "dhone-pd-restore-$runId"
$volumeName = "dhone-pd-restore-data-$runId"
$resumeMode = -not [string]::IsNullOrWhiteSpace($ResumeContainer)
if ($resumeMode) {
    if ($ResumeContainer -notmatch '^dhone-pd-restore-[0-9a-f]{32}$') {
        throw 'ResumeContainer must be a temporary Dhone recovery container.'
    }
    $previous = @((Invoke-DhoneDocker -DockerArgs @('inspect', '--type', 'container', $ResumeContainer)) -join "`n" | ConvertFrom-Json)[0]
    if ($previous.Config.Labels.'dhone.lab.purpose' -ne 'restore-test' -or
        $previous.State.Status -ne 'exited' -or $previous.Image -ne $pdImage -or
        $previous.HostConfig.NetworkMode -ne 'none') {
        throw 'Resume requires a stopped, isolated recovery container using the saved PD image.'
    }
    $previousData = @($previous.Mounts | Where-Object { $_.Destination -eq '/opt/out' -and $_.Type -eq 'volume' })
    if ($previousData.Count -ne 1 -or $previousData[0].Name -notmatch '^dhone-pd-restore-data-[0-9a-f]{32}$') {
        throw 'The retained recovery volume could not be identified safely.'
    }
    $volumeName = [string]$previousData[0].Name
    $savedVolume = @((Invoke-DhoneDocker -DockerArgs @('volume', 'inspect', $volumeName)) -join "`n" | ConvertFrom-Json)[0]
    if ($savedVolume.Labels.'dhone.lab.purpose' -ne 'restore-test') {
        throw 'The retained volume is not labeled as a recovery test.'
    }
    $activeUsers = @(Invoke-DhoneDocker -DockerArgs @('ps', '--filter', "volume=$volumeName", '--format', '{{.Names}}'))
    if ($activeUsers.Count -gt 0) { throw 'Another running container is using the recovery volume.' }
    $previousLog = (Invoke-DhoneDocker -DockerArgs @('logs', $ResumeContainer)) -join "`n"
    if ($previousLog -notmatch 'The restore process completed successfully') {
        throw 'The retained run does not show a completed restore. Review it before resuming.'
    }
    Write-Host 'Resuming the restored test volume; setup and restore will be skipped.'
}
$runDirectory = Join-Path $env:USERPROFILE "DhoneLab\recovery-tests\$runId"
New-Item -ItemType Directory -Path $runDirectory | Out-Null
$helperPath = Join-Path $runDirectory 'restore-userroot.sh'
$logPath = Join-Path $runDirectory 'restore.log'
$helper = @'
#!/bin/sh
set -eu
umask 077
export JAVA_HOME=/opt/java
export PATH=/opt/java/bin:$PATH
root=/opt/out/instance
started=0
server_pid=''
cleanup() {
    cleanup_status=$?
    if [ "$cleanup_status" -ne 0 ] && [ -f "$root/logs/dhone-startup.log" ]; then
        echo 'DIAGNOSTIC: Last startup log lines:' >&2
        tail -n 30 "$root/logs/dhone-startup.log" >&2
    fi
    if [ "$started" = 1 ]; then
        timeout 30 "$root/bin/stop-server" >/dev/null 2>&1 || true
    fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

if ! command -v timeout >/dev/null 2>&1; then
    echo 'FAIL: The image needs the timeout utility for bounded readiness checks.' >&2
    exit 9
fi
if [ ! -x /opt/server/setup ] || [ ! -x /opt/java/bin/java ]; then
    echo 'FAIL: This image layout needs review: /opt/server/setup or /opt/java/bin/java is missing.' >&2
    exit 10
fi
if [ "${DHONE_RECOVERY_RESUME:-false}" = 'true' ]; then
    if [ ! -x "$root/bin/start-server" ] || [ ! -f "$root/config/config.ldif" ] || [ ! -d "$root/db/userRoot" ]; then
        echo 'FAIL: The retained volume does not contain a configured userRoot instance.' >&2
        exit 12
    fi
    cd "$root"
    echo 'RECOVERY: Reusing the completed userRoot restore; skipping setup and restore.'
else
if [ -e "$root" ]; then
    echo 'FAIL: Recovery instance already exists; refusing to overwrite it.' >&2
    exit 11
fi
echo 'RECOVERY: Creating a fresh standalone instance from the local product image.'
mkdir -p "$root"
cp -a /opt/server/. "$root/"
cd "$root"
./setup --noPropertiesFile --no-prompt --acceptLicense \
    --licenseKeyFile /backup/PingDirectory.lic \
    --instanceName DhonePDRecovery --location LocalRecoveryLab \
    --localHostName dhone-pd-recovery.test --listenAddress 127.0.0.1 \
    --ldapPort 1389 --ldapsPort 1636 --enableStartTLS \
    --generateSelfSignedCertificate \
    --rootUserDN 'cn=Directory Manager' \
    --rootUserPasswordFile /backup/pd-secrets/root-password \
    --baseDN dc=dhone,dc=in --addBaseEntry \
    --encryptDataWithSettingsImportedFromFile /backup/pingdirectory-native/encryption-settings.export \
    --encryptionSettingsExportPassphraseFile /backup/pd-secrets/encryption-password \
    --jvmTuningParameter AGGRESSIVE --maxHeapSize 1024m --doNotStart

echo 'RECOVERY: Restoring userRoot into the new instance while it is offline.'
./bin/restore \
    --backupDirectory /backup/pingdirectory-native/backends/userRoot \
    --encryptionPassphraseFile /backup/pd-secrets/encryption-password
fi

echo 'RECOVERY: Starting the recovered directory inside the isolated container.'
started=1
./bin/start-server --nodetach > logs/dhone-startup.log 2>&1 &
server_pid=$!
search() {
    timeout 30 ./bin/ldapsearch --noPropertiesFile --hostname 127.0.0.1 --port 1389 \
        --bindDN 'cn=Directory Manager' \
        --bindPasswordFile /backup/pd-secrets/root-password "$@"
}
echo 'RECOVERY: Waiting for authenticated LDAP readiness (up to about 3 minutes).'
ready_deadline=$(( $(date +%s) + 180 ))
until search --baseDN dc=dhone,dc=in --scope base '(objectClass=*)' dc > logs/dhone-readiness.ldif 2> logs/dhone-readiness.err; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo 'FAIL: The server process exited before LDAP became ready.' >&2
        tail -n 15 logs/dhone-readiness.err >&2
        exit 30
    fi
    if [ "$(date +%s)" -ge "$ready_deadline" ]; then
        echo 'FAIL: LDAP readiness timed out.' >&2
        tail -n 15 logs/dhone-readiness.err >&2
        exit 31
    fi
    sleep 3
done
grep -F -i -x -q 'dc: dhone' logs/dhone-readiness.ldif
echo 'CHECK: Authenticated LDAP readiness succeeded.'
search --baseDN dc=dhone,dc=in --scope one \
    '(objectClass=organizationalUnit)' ou > logs/dhone-recovered-ous.ldif
for ou in Employees Admins HR StakeHolders Customers Agents Partners Bots AIAgents People VIP Guest groups services; do
    if ! grep -F -i -x -q "ou: $ou" logs/dhone-recovered-ous.ldif; then
        echo "FAIL: Required OU missing after restore: $ou" >&2
        exit 20
    fi
done
echo 'CHECK: All 14 required OUs are present.'

search --baseDN 'uid=employee01,ou=Employees,dc=dhone,dc=in' --scope base \
    '(objectClass=inetOrgPerson)' uid employeeNumber > logs/dhone-recovered-employee.ldif
grep -F -i -x -q 'uid: employee01' logs/dhone-recovered-employee.ldif
grep -F -i -x -q 'employeeNumber: EMP001' logs/dhone-recovered-employee.ldif
echo 'CHECK: employee01 and employee number EMP001 are present.'

search --baseDN 'cn=Employees,ou=groups,dc=dhone,dc=in' --scope base \
    '(objectClass=groupOfNames)' member > logs/dhone-recovered-group.ldif
grep -F -i -x -q 'member: uid=employee01,ou=Employees,dc=dhone,dc=in' logs/dhone-recovered-group.ldif
echo 'CHECK: Employees group contains employee01.'

search --baseDN 'uid=svc-pingfederate,ou=services,dc=dhone,dc=in' --scope base \
    '(objectClass=*)' uid > logs/dhone-recovered-service.ldif
grep -F -i -x -q 'uid: svc-pingfederate' logs/dhone-recovered-service.ldif
echo 'CHECK: svc-pingfederate is present.'

echo 'RECOVERY: Entry checks passed; stopping the test server.'
timeout 60 ./bin/stop-server
shutdown_attempt=0
while kill -0 "$server_pid" 2>/dev/null; do
    shutdown_attempt=$(( shutdown_attempt + 1 ))
    if [ "$shutdown_attempt" -ge 30 ]; then
        echo 'FAIL: Server process did not exit after the stop request.' >&2
        exit 32
    fi
    sleep 1
done
server_exit=0
wait "$server_pid" || server_exit=$?
case "$server_exit" in
    0|143) ;;
    *) echo "FAIL: Unexpected server exit after shutdown: $server_exit" >&2; exit 33 ;;
esac
started=0
echo 'DHONE_USERROOT_RESTORE_PASS'
'@
[IO.File]::WriteAllText($helperPath, $helper.Replace("`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))

$containerCreated = $false
$volumeCreated = $false
$recoveryPassed = $false
$resourcesRemoved = $false
$failure = $null
try {
    Write-Host '[2/5] Creating an isolated recovery container (2 GB RAM, no network or host ports)...'
    if (-not $resumeMode) {
        Invoke-DhoneDocker -DockerArgs @(
            'volume', 'create', '--label', 'dhone.lab.purpose=restore-test',
            '--label', "dhone.lab.run=$runId", $volumeName
        ) | Out-Null
    }
    $volumeCreated = $true
    Invoke-DhoneDocker -DockerArgs @(
        'run', '--detach', '--pull', 'never', '--name', $containerName,
        '--hostname', 'dhone-pd-recovery.test', '--network', 'none',
        '--add-host', 'dhone-pd-recovery.test:127.0.0.1',
        '--add-host', 'dhone-pd-recovery:127.0.0.1',
        '--memory', '2g', '--cpus', '2', '--init', '--no-healthcheck',
        '--user', '0:0', '--label', 'dhone.lab.purpose=restore-test',
        '--label', "dhone.lab.run=$runId",
        '--env', ('DHONE_RECOVERY_RESUME=' + $resumeMode.ToString().ToLowerInvariant()),
        '--mount', "type=volume,source=$volumeName,target=/opt/out",
        '--mount', "type=bind,source=$BackupPath,target=/backup,readonly",
        '--mount', "type=bind,source=$helperPath,target=/run/dhone-restore.sh,readonly",
        '--entrypoint', '/bin/sh', $pdImage, '/run/dhone-restore.sh'
    ) | Out-Null
    $containerCreated = $true
    Write-Host '[3/5] Running recovery and entry checks; full output is saved to restore.log...'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $state = (Invoke-DhoneDocker -DockerArgs @('inspect', '--format', '{{.State.Status}}', $containerName)) -join ''
        if ($state.Trim() -in @('exited', 'dead')) { break }
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            throw "Recovery exceeded $TimeoutSeconds seconds. The temporary copy will be stopped."
        }
        Write-Progress -Activity 'Dhone PD userRoot restore test' -Status ("Elapsed: {0}s" -f [int]$watch.Elapsed.TotalSeconds)
        Start-Sleep -Seconds 2
    }
    Write-Progress -Activity 'Dhone PD userRoot restore test' -Completed
    $logLines = @(Invoke-DhoneDocker -DockerArgs @('logs', $containerName))
    $logLines | Set-Content -LiteralPath $logPath -Encoding UTF8
    $exitCode = [int]((Invoke-DhoneDocker -DockerArgs @('inspect', '--format', '{{.State.ExitCode}}', $containerName)) -join '')
    if ($exitCode -ne 0 -or $logLines -cnotcontains 'DHONE_USERROOT_RESTORE_PASS') {
        $logLines | Select-Object -Last 35 | ForEach-Object { Write-Host $_ }
        throw "Recovery did not pass (container exit code $exitCode). Log: $logPath"
    }
    $recoveryPassed = $true
    Write-Host '[4/5] PASS - userRoot was restored and the recovered entries were verified.'
    $logLines | Where-Object { $_.StartsWith('CHECK:') } | ForEach-Object { Write-Host $_ }
}
catch { $failure = $_ }
finally {
    Write-Progress -Activity 'Dhone PD userRoot restore test' -Completed
    if ($containerCreated -and -not $recoveryPassed) {
        try {
            Invoke-DhoneDocker -DockerArgs @('stop', '--timeout', '30', $containerName) | Out-Null
            Invoke-DhoneDocker -DockerArgs @('logs', $containerName) |
                Set-Content -LiteralPath $logPath -Encoding UTF8
        }
        catch { Write-Warning 'Could not finish stopping or collecting logs from the temporary recovery container.' }
    }
    if ($recoveryPassed) {
        Write-Host '[5/5] Removing this test container and its dedicated volume...'
        try {
            Invoke-DhoneDocker -DockerArgs @('rm', '--volumes', $containerName) | Out-Null
            if ($resumeMode) {
                Invoke-DhoneDocker -DockerArgs @('rm', '--volumes', $ResumeContainer) | Out-Null
            }
            Invoke-DhoneDocker -DockerArgs @('volume', 'rm', $volumeName) | Out-Null
            $resourcesRemoved = $true
        }
        catch { Write-Warning "Recovery passed; temporary resource cleanup needs review. Container: $containerName; volume: $volumeName" }
    }
}

if ($null -ne $failure) {
    if ($volumeCreated) { Write-Host "Retained recovery volume: $volumeName" }
    if ($containerCreated) { Write-Host "Recovery container: $containerName" }
    Write-Host "Recovery log (if collected): $logPath"
    throw $failure
}
[pscustomobject]@{
    Result = 'PASS'
    Scope = 'PingDirectory userRoot data restore'
    RequiredOUs = 14
    Employee = 'employee01 / EMP001'
    EmployeesGroupMembership = 'Verified'
    ServiceAccount = 'svc-pingfederate found'
    TemporaryResourcesRemoved = $resourcesRemoved
    Log = $logPath
} | Format-List
