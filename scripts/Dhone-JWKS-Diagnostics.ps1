#requires -Version 5.1
<#
Dhone JWKS transport diagnostics v1.0. No login or bearer tokens are used.
Reads the public PF certificate and requests only /pf/JWKS inside pingaccess.
No product settings, certificates, trust stores or containers are changed.
A unique temporary public certificate is copied and removed as container root.
The OpenSSL matrix varies SNI and HTTP Host independently while verifying the
certificate chain and the configured certificate identity, localhost.
References: https://docs.openssl.org/3.0/man1/openssl-s_client/
https://curl.se/docs/manpage.html
#>
[CmdletBinding()]
param([string]$CertificatePath = (Join-Path $env:USERPROFILE 'DhoneLab\certs\pf-runtime.pem'))
$ErrorActionPreference = 'Stop'
$temporaryCa = '/tmp/dhone-jwks-probe-' + [guid]::NewGuid().ToString('N') + '.pem'
$copied = $false
$failed = $false

function Invoke-ProbeDocker {
    param([string[]]$Arguments, [string]$InputText)
    $ErrorActionPreference = 'Continue'
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $lines = @($InputText | & docker.exe --context desktop-linux @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    } else {
        $lines = @(& docker.exe --context desktop-linux @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

function Get-ProbeSummary {
    param([string]$Probe, [string]$Sni, [string]$HttpHost, $Result)
    $text = $Result.Lines -join "`n"
    $http = [regex]::Match($text, '(?m)^HTTP/1\.[01]\s+(\d{3})')
    $status = if ($http.Success) { $http.Groups[1].Value } else { 'none' }
    $detail = 'No HTTP response'
    if ($http.Success) {
        if ($text -match '"keys"\s*:\s*\[') { $detail = 'JWKS JSON' }
        else {
            $title = [regex]::Match($text, '(?is)<(?:title|h1|h2)[^>]*>(.*?)</(?:title|h1|h2)>')
            if ($title.Success) {
                $detail = [Net.WebUtility]::HtmlDecode(($title.Groups[1].Value -replace '<[^>]+>', ' '))
                $detail = ($detail -replace '\s+', ' ').Trim()
            } else { $detail = 'Non-JWKS response' }
        }
    } else {
        $errorLines = @($Result.Lines | Where-Object { $_ -match '(?i)error|failed|not found|timed out|connect|verify' })
        if ($errorLines.Count -gt 0) { $detail = $errorLines[-1] }
    }
    if ($detail.Length -gt 130) { $detail = $detail.Substring(0,130) }
    [pscustomobject]@{ Probe=$Probe; SNI=$Sni; HTTPHost=$HttpHost; HTTP=$status; ToolExit=$Result.ExitCode; Detail=$detail }
}

try {
    Write-Host 'Dhone JWKS transport diagnostics v1.0'
    $null = Get-Command docker.exe -CommandType Application -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) { throw "Missing public certificate: $CertificatePath" }
    $context = Invoke-ProbeDocker -Arguments @('context','inspect','desktop-linux','--format','{{.Endpoints.docker.Host}}')
    if ($context.ExitCode -ne 0 -or ($context.Lines -join '') -notlike 'npipe:////./pipe/*') {
        throw 'desktop-linux must be the local Windows Docker Desktop context.'
    }
    $copy = Invoke-ProbeDocker -Arguments @('cp',$CertificatePath,('pingaccess:' + $temporaryCa))
    if ($copy.ExitCode -ne 0) { throw ('Public certificate copy failed: ' + ($copy.Lines -join ' ')) }
    $copied = $true

    Write-Host '[1/3] Checking curl with HTTP/1.1...'
    $curl = Invoke-ProbeDocker -Arguments @('exec','pingaccess','curl',
        '--disable','--silent','--show-error','--include','--http1.1',
        '--noproxy','*','--connect-timeout','5','--max-time','15',
        '--cacert',$temporaryCa,'--connect-to','localhost:9031:pingfederate:9031',
        'https://localhost:9031/pf/JWKS')
    $rows = @(Get-ProbeSummary 'curl-H1' 'localhost' 'localhost:9031' $curl)

    Write-Host '[2/3] Checking TLS server-name and HTTP Host combinations...'
    $available = Invoke-ProbeDocker -Arguments @('exec','pingaccess','sh','-c','command -v openssl && command -v timeout')
    if ($available.ExitCode -eq 0) {
        foreach ($sni in @('localhost','pingfederate')) {
            foreach ($httpHost in @('localhost','pingfederate')) {
                $requestText = "GET /pf/JWKS HTTP/1.1`r`nHost: ${httpHost}:9031`r`nConnection: close`r`n`r`n"
                $probe = Invoke-ProbeDocker -Arguments @('exec','-i','pingaccess','timeout','15',
                    'openssl','s_client','-quiet','-ign_eof','-connect','pingfederate:9031',
                    '-servername',$sni,'-alpn','http/1.1','-verify_hostname','localhost',
                    '-verify_return_error','-CAfile',$temporaryCa) -InputText $requestText
                $rows += Get-ProbeSummary 'openssl-H1' $sni ($httpHost + ':9031') $probe
            }
        }
    } else {
        Write-Host 'OpenSSL matrix skipped: openssl or timeout is not installed in pingaccess. No packages were installed.'
    }
    $rows | Format-Table -AutoSize -Wrap

    Write-Host '[3/3] Reading relevant errors from the discovered PF server log...'
    $log = Invoke-ProbeDocker -Arguments @('exec','pingfederate','tail','-n','600','/opt/pingidentity/runtime/log/server.log')
    if ($log.ExitCode -ne 0) { Write-Host ('Log read failed: ' + ($log.Lines -join ' ')) }
    else {
        $matches = @($log.Lines | Where-Object { $_ -match '(?i)SNI|BadMessage|Invalid Host|Bad Request' } | Select-Object -Last 12)
        if ($matches.Count -eq 0) { Write-Host 'No matching PF server-log entries.' }
        foreach ($line in $matches) {
            $line -replace '(?i)Bearer\s+\S+', 'Bearer [REDACTED]' -replace '[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[JWT REDACTED]'
        }
    }
    Write-Host 'Diagnostic collection complete. Share the table and the short error section; no login is needed.'
} catch {
    $failed = $true
    Write-Host ('FAIL: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($copied) {
        $cleanup = Invoke-ProbeDocker -Arguments @('exec','--user','0','pingaccess','rm','-f',$temporaryCa)
        if ($cleanup.ExitCode -ne 0) { Write-Warning ('Temporary public-certificate cleanup failed: ' + $temporaryCa) }
    }
}
if ($failed) { exit 1 }
