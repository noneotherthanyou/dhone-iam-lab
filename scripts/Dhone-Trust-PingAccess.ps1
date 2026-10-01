#requires -Version 5.1
<#
Trust the initial PingAccess localhost Admin or Engine certificate for this Windows user.
Uses the existing PingDirectory certificate tool to retrieve the public leaf
certificate from the IP Docker assigns to pingaccess on identitylab.
Then checks the Windows localhost endpoint with normal TLS validation and an
exact certificate comparison. No passwords, private keys or license data used.
Sources: PingDirectory manage-certificates CLI; PingAccess 9.1 HTTPS listeners.
#>
[CmdletBinding()]
param(
    [ValidateSet('Admin','Engine')]
    [string]$Endpoint = 'Admin'
)
$ErrorActionPreference = 'Stop'
$paListenerPort = if ($Endpoint -eq 'Engine') { 3000 } else { 9000 }
$paListenerLabel = $Endpoint.ToLowerInvariant()
$paListenerUrl = 'https://localhost:' + $paListenerPort
$paAdded = $false
$paCert = $null
$paClient = $null
$paTls = $null
$paTemp = '/tmp/dhone-pa-' + $paListenerLabel + '-' + [guid]::NewGuid().ToString('N') + '.cer'
$paStorePath = $null

function Invoke-PaDocker([string[]]$Arguments, [switch]$AllowFailure) {
    $ErrorActionPreference = 'Continue'
    $lines = @(& docker.exe --context desktop-linux @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("Docker {0} failed: {1}" -f $Arguments[0], (($lines | Select-Object -Last 10) -join "`n"))
    }
    return $lines
}

try {
    Write-Host ('Dhone PingAccess certificate trust v1.2 - ' + $Endpoint)
    Write-Host '[1/4] Checking the local containers...'
    $null = Get-Command docker.exe -CommandType Application -ErrorAction Stop
    $paEndpoint = (Invoke-PaDocker -Arguments @('context','inspect','desktop-linux','--format','{{.Endpoints.docker.Host}}') | Select-Object -Last 1)
    if (-not $paEndpoint.StartsWith('npipe:////./pipe/', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'desktop-linux must be the local Windows Docker Desktop context.'
    }
    foreach ($paName in @('pingaccess','pingdirectory')) {
        $paRunning = Invoke-PaDocker -Arguments @('inspect','--type','container','--format','{{.State.Running}}',$paName)
        if (($paRunning -join '').Trim() -ne 'true') { throw "$paName must be running." }
    }
    # Windows PowerShell 5.1 can strip embedded quotes passed to docker.exe.
    # Request JSON without quoted template keys; select the keys in PowerShell.
    $paNetworkFormat = '{{json .NetworkSettings.Networks}}'
    $paNetworks = (Invoke-PaDocker -Arguments @('inspect','--type','container','--format',$paNetworkFormat,'pingaccess') -join '') | ConvertFrom-Json
    $pdNetworks = (Invoke-PaDocker -Arguments @('inspect','--type','container','--format',$paNetworkFormat,'pingdirectory') -join '') | ConvertFrom-Json
    $paIp = ([string]$paNetworks.identitylab.IPAddress).Trim()
    $pdIp = ([string]$pdNetworks.identitylab.IPAddress).Trim()
    if (-not $paIp -or -not $pdIp) { throw 'Both containers must be on identitylab.' }
    $paPortFormat = '{{json .NetworkSettings.Ports}}'
    $paPortMap = (Invoke-PaDocker -Arguments @('inspect','--type','container','--format',$paPortFormat,'pingaccess') -join '') | ConvertFrom-Json
    $paPorts = $paPortMap."${paListenerPort}/tcp"
    if (@($paPorts | Where-Object { $_.HostIp -eq '127.0.0.1' -and $_.HostPort -eq [string]$paListenerPort }).Count -ne 1) {
        throw "Expected PingAccess $paListenerLabel binding 127.0.0.1:$paListenerPort was not found."
    }

    Write-Host "[2/4] Retrieving the public $paListenerLabel certificate through the lab network..."
    $null = Invoke-PaDocker -Arguments @('exec','pingdirectory','/opt/out/instance/bin/manage-certificates',
        'retrieve-server-certificate','--hostname',$paIp,'--port',([string]$paListenerPort),
        '--only-peer-certificate','--output-file',$paTemp,'--output-format','DER')
    $paCertDir = Join-Path $env:USERPROFILE 'DhoneLab\certs'
    $null = New-Item -ItemType Directory -Force -Path $paCertDir
    $paCertPath = Join-Path $paCertDir ('pa-' + $paListenerLabel + '.cer')
    $null = Invoke-PaDocker -Arguments @('cp',('pingdirectory:' + $paTemp),$paCertPath)
    $paCert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($paCertPath)
    $paDns = $paCert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)
    if ($paCert.Subject -ne $paCert.Issuer -or $paDns -ne 'localhost') {
        throw "Expected the initial self-issued localhost certificate. Found subject '$($paCert.Subject)', DNS '$paDns'. Trust was not changed."
    }
    $paNow = [datetime]::UtcNow
    if ($paNow -lt $paCert.NotBefore.ToUniversalTime() -or $paNow -gt $paCert.NotAfter.ToUniversalTime()) {
        throw 'The PA certificate is outside its validity window. Trust was not changed.'
    }
    $paHash = [Security.Cryptography.SHA256]::Create()
    try { $paFingerprint = [BitConverter]::ToString($paHash.ComputeHash($paCert.RawData)).Replace('-','') }
    finally { $paHash.Dispose() }
    Write-Host ('Certificate: ' + $paCert.Subject)
    Write-Host ('SHA-256: ' + $paFingerprint)
    Write-Host ('Expires: ' + $paCert.NotAfter.ToString('yyyy-MM-dd'))

    Write-Host '[3/4] Trusting this certificate in your Windows user certificate store...'
    $paStorePath = 'Cert:\CurrentUser\Root\' + $paCert.Thumbprint
    if (-not (Test-Path -LiteralPath $paStorePath)) {
        $paAdded = $true
        $null = Import-Certificate -FilePath $paCertPath -CertStoreLocation 'Cert:\CurrentUser\Root'
    }

    Write-Host "[4/4] Validating TLS for localhost:$paListenerPort and comparing the certificate..."
    $paClient = [Net.Sockets.TcpClient]::new()
    if (-not $paClient.ConnectAsync('127.0.0.1',$paListenerPort).Wait(10000)) { throw "Connection to localhost:$paListenerPort timed out." }
    # No custom validation callback: Windows checks trust, validity and hostname.
    $paTls = [Net.Security.SslStream]::new($paClient.GetStream(), $false)
    $paAsync = $paTls.BeginAuthenticateAsClient('localhost', $null,
        [Security.Authentication.SslProtocols]::Tls12, $false, $null, $null)
    try {
        if (-not $paAsync.AsyncWaitHandle.WaitOne(10000)) { throw 'TLS negotiation timed out.' }
        $paTls.EndAuthenticateAsClient($paAsync)
    } finally { $paAsync.AsyncWaitHandle.Close() }
    $paPresented = [Convert]::ToBase64String($paTls.RemoteCertificate.GetRawCertData())
    if ($paPresented -cne [Convert]::ToBase64String($paCert.RawData)) {
        throw 'The Windows endpoint certificate does not match the PingAccess container certificate.'
    }
    [pscustomobject]@{
        Result = 'PASS'
        Endpoint = $Endpoint
        TLSValidation = 'Trust, hostname and validity verified'
        ContainerCertificateMatches = $true
        TrustStore = 'CurrentUser\Root'
        CertificateFile = $paCertPath
        Url = $paListenerUrl
        NextCheck = $(if ($Endpoint -eq 'Engine') { 'Test the protected API at https://localhost:3000/lab/data' } else { 'Sign in, then Settings > System > License' })
    } | Format-List
} catch {
    $paFailure = $_.Exception.Message
    if ($paAdded -and $paStorePath -and (Test-Path -LiteralPath $paStorePath)) {
        try { Remove-Item -LiteralPath $paStorePath -ErrorAction Stop }
        catch { Write-Warning ('Could not undo the certificate import: ' + $_.Exception.Message) }
    }
    Write-Host ('FAIL: ' + $paFailure) -ForegroundColor Red
    exit 1
} finally {
    if ($paTls) { $paTls.Dispose() }
    if ($paClient) { $paClient.Dispose() }
    if ($paCert) { $paCert.Dispose() }
    if (Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue) {
        $null = Invoke-PaDocker -Arguments @('exec','pingdirectory','rm','-f',$paTemp) -AllowFailure
    }
}
