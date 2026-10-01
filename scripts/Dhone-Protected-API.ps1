#requires -Version 5.1
<#
Dhone IAM teaching API v1.1: GET http://127.0.0.1:8766/lab/data.
Loopback-only HTTP for this local exercise. Do not publish it or use real data.
PF signing keys are fetched over certificate-validated HTTPS. A later PingAccess
POC will add the HTTPS gateway. This is a teaching implementation, not an SDK.
Startup self-checks use an ephemeral test key; real requests use only PF keys.
No tokens, request headers or private keys are logged or written to disk.
#>
[CmdletBinding()]
param([string]$CertificatePath = (Join-Path $env:USERPROFILE 'DhoneLab\certs\pf-runtime.pem'))
$ErrorActionPreference = 'Stop'
$apiIssuer = 'https://localhost:9031'
$apiAudience = 'urn:dhone:lab:api'
$apiScope = 'lab.read'
$apiStopFile = Join-Path $PSScriptRoot 'Dhone-API.stop'
$server = $null

function Decode-Base64Url([string]$Value) {
    if ($Value -cnotmatch '^[A-Za-z0-9_-]+$' -or $Value.Length % 4 -eq 1) { throw 'malformed_token' }
    $text = $Value.Replace('-','+').Replace('_','/')
    $text += '=' * ((4 - $text.Length % 4) % 4)
    return ,([Convert]::FromBase64String($text))
}

function Read-AccessToken([string]$Token, $Jwks) {
    $parts = $Token.Split('.')
    if ($parts.Length -ne 3 -or $Token.Length -gt 16384) { throw 'malformed_token' }
    try {
        $header = [Text.Encoding]::UTF8.GetString((Decode-Base64Url $parts[0])) | ConvertFrom-Json
        $claims = [Text.Encoding]::UTF8.GetString((Decode-Base64Url $parts[1])) | ConvertFrom-Json
    } catch { throw 'malformed_token' }
    if ($header.alg -cne 'RS256' -or $null -ne $header.crit -or $header.b64 -eq $false) { throw 'algorithm' }
    $keys = @($Jwks.keys | Where-Object {
        $_.kty -ceq 'RSA' -and (-not $_.use -or $_.use -ceq 'sig') -and
        (-not $_.alg -or $_.alg -ceq 'RS256') -and
        (-not $_.key_ops -or @($_.key_ops) -ccontains 'verify') -and
        (-not $header.kid -or $_.kid -ceq $header.kid)
    })
    if ($keys.Count -ne 1) { throw 'signing_key' }
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $parameters = New-Object Security.Cryptography.RSAParameters
        $parameters.Modulus = Decode-Base64Url $keys[0].n
        $parameters.Exponent = Decode-Base64Url $keys[0].e
        $rsa.ImportParameters($parameters)
        if ($rsa.KeySize -lt 2048) { throw 'signing_key' }
        $ok = $rsa.VerifyData([Text.Encoding]::ASCII.GetBytes($parts[0] + '.' + $parts[1]),
            (Decode-Base64Url $parts[2]), [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $ok) { throw 'signature' }
    } finally { $rsa.Dispose() }
    if ($claims.iss -cne $apiIssuer) { throw 'issuer' }
    if (@($claims.aud) -cnotcontains $apiAudience) { throw 'audience' }
    if ($claims.sub -isnot [string] -or [string]::IsNullOrWhiteSpace($claims.sub)) { throw 'subject' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (($claims.exp -isnot [int] -and $claims.exp -isnot [long]) -or $claims.exp -le ($now - 60)) { throw 'expiry' }
    foreach ($name in @('iat','nbf')) {
        if ($null -ne $claims.$name -and
            (($claims.$name -isnot [int] -and $claims.$name -isnot [long]) -or $claims.$name -gt ($now + 60))) {
            throw 'token_time'
        }
    }
    if ($null -ne $claims.iat -and $claims.exp -le $claims.iat) { throw 'token_time' }
    if ($null -ne $claims.scope -and $claims.scope -isnot [string]) { throw 'scope_format' }
    return $claims
}

function Get-AccessDecision([string]$Token, $Jwks) {
    if (-not $Token) { return [pscustomobject]@{Status=401; Error=''; Reason='missing_token'; Subject=''} }
    try { $claims = Read-AccessToken $Token $Jwks }
    catch {
        $reason = $_.Exception.Message
        if ($reason -cnotmatch '^(malformed_token|algorithm|signing_key|signature|issuer|audience|subject|expiry|token_time|scope_format)$') { $reason = 'malformed_token' }
        return [pscustomobject]@{Status=401; Error='invalid_token'; Reason=$reason; Subject=''}
    }
    if (@(([string]$claims.scope).Split(' ')) -cnotcontains $apiScope) {
        return [pscustomobject]@{Status=403; Error='insufficient_scope'; Reason='insufficient_scope'; Subject=''}
    }
    return [pscustomobject]@{Status=200; Error=''; Reason='allowed'; Subject=$claims.sub}
}

function Get-PfSigningKeys {
    $raw = @(& $script:curlPath '--disable' '--silent' '--show-error' '--fail' '--proto' '=https' `
        '--noproxy' 'localhost' '--connect-timeout' '10' '--max-time' '30' `
        '--cacert' $CertificatePath "$apiIssuer/pf/JWKS")
    if ($LASTEXITCODE -ne 0) { throw 'PF JWKS HTTPS request failed.' }
    $result = ($raw -join "`n") | ConvertFrom-Json
    if (-not $result.keys) { throw 'PF JWKS contains no signing keys.' }
    return $result
}

function Send-ApiResponse($Stream, [int]$Status, [string]$Reason, [string]$OAuthError = '', [string]$Subject = '') {
    $body = [ordered]@{api='dhone-lab-v1'; reason=$Reason}
    if ($OAuthError) { $body['error'] = $OAuthError }
    if ($Status -eq 200) {
        $body['subject'] = $Subject
        $body['data'] = 'Fictional Dhone lab data: read permitted.'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))
    $phrases = @{200='OK'; 400='Bad Request'; 401='Unauthorized'; 403='Forbidden'; 404='Not Found'; 405='Method Not Allowed'; 503='Service Unavailable'}
    $challenge = ''
    if ($Status -eq 401 -or $Status -eq 403) {
        $challenge = 'WWW-Authenticate: Bearer realm="dhone-lab"'
        if ($OAuthError) { $challenge += ', error="' + $OAuthError + '"' }
        if ($Status -eq 403) { $challenge += ', scope="lab.read"' }
        $challenge += "`r`n"
    }
    $allow = if ($Status -eq 405) { "Allow: GET`r`n" } else { '' }
    $head = "HTTP/1.1 $Status $($phrases[$Status])`r`nContent-Type: application/json; charset=utf-8`r`n" +
        "Cache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n" +
        $challenge + $allow + "Connection: close`r`nContent-Length: $($bytes.Length)`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headerBytes,0,$headerBytes.Length)
    $Stream.Write($bytes,0,$bytes.Length)
    $Stream.Flush()
    Write-Host ("{0} /lab/data ({1})" -f $Status,$Reason)
}

function Invoke-StartupChecks {
    # Signed fixtures prove the claim checks after a valid signature, not just
    # rejection of unsigned garbage. The key is discarded before serving.
    # Choose the key size in the Windows CNG constructor. Some RSA providers
    # expose KeySize as read-only through Windows PowerShell's object adapter.
    $key = [Security.Cryptography.RSACng]::new(2048)
    function Encode-TestBytes([byte[]]$Bytes) {
        [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    }
    try {
        $public = $key.ExportParameters($false)
        $testKeys = [pscustomobject]@{keys=@([pscustomobject]@{kty='RSA';use='sig';alg='RS256';kid='self-check';n=(Encode-TestBytes $public.Modulus);e=(Encode-TestBytes $public.Exponent)})}
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $cases = @(
            @{Name='valid'; Status=200; Reason='allowed'},
            @{Name='issuer'; Claim='iss'; Value='https://wrong.example'; Status=401; Reason='issuer'},
            @{Name='audience'; Claim='aud'; Value='dhone-desktop-pkce'; Status=401; Reason='audience'},
            @{Name='expired'; Claim='exp'; Value=($now-120); Status=401; Reason='expiry'},
            @{Name='future'; Claim='nbf'; Value=($now+600); Status=401; Reason='token_time'},
            @{Name='missing-scope'; Claim='scope'; Value='openid'; Status=403; Reason='insufficient_scope'},
            @{Name='scope-case'; Claim='scope'; Value='openid LAB.READ'; Status=403; Reason='insufficient_scope'},
            @{Name='signature'; Status=401; Reason='signature'},
            @{Name='algorithm'; Status=401; Reason='algorithm'},
            @{Name='no-token'; Status=401; Reason='missing_token'}
        )
        foreach ($case in $cases) {
            $claims = [ordered]@{iss=$apiIssuer;aud=$apiAudience;sub='self-check';iat=$now;exp=($now+300);scope='openid lab.read'}
            if ($case.Claim) { $claims[$case.Claim] = $case.Value }
            $alg = if ($case.Name -eq 'algorithm') { 'HS256' } else { 'RS256' }
            $header = [ordered]@{alg=$alg;kid='self-check'} | ConvertTo-Json -Compress
            $payload = $claims | ConvertTo-Json -Compress
            $inputText = (Encode-TestBytes ([Text.Encoding]::UTF8.GetBytes($header))) + '.' + (Encode-TestBytes ([Text.Encoding]::UTF8.GetBytes($payload)))
            $signature = $key.SignData([Text.Encoding]::ASCII.GetBytes($inputText), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            if ($case.Name -eq 'signature') { $signature[0] = $signature[0] -bxor 1 }
            $token = $inputText + '.' + (Encode-TestBytes $signature)
            if ($case.Name -eq 'no-token') { $token = '' }
            $decision = Get-AccessDecision $token $testKeys
            if ($decision.Status -ne $case.Status -or $decision.Reason -cne $case.Reason) {
                throw ("API self-check failed: {0}; expected {1}/{2}, got {3}/{4}" -f $case.Name,$case.Status,$case.Reason,$decision.Status,$decision.Reason)
            }
        }
        Write-Host 'PASS: 10 local API validation self-checks.' -ForegroundColor Green
    } finally { $key.Dispose() }
}

try {
    # A previous shutdown request must not prevent a new explicit start.
    if (Test-Path -LiteralPath $apiStopFile) { Remove-Item -LiteralPath $apiStopFile -Force }
    Invoke-StartupChecks
    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) { throw 'PF runtime certificate file is missing.' }
    $script:curlPath = (Get-Command curl.exe -CommandType Application -ErrorAction Stop).Source
    $jwks = Get-PfSigningKeys
    $keysExpire = [datetime]::UtcNow.AddMinutes(5)
    $server = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'),8766)
    $server.Start()
    Write-Host 'Dhone API v1.1 - Docker host routing enabled; bearer token and lab.read required.'
    Write-Host 'API ready: http://127.0.0.1:8766/lab/data - requires lab.read. Ctrl+C stops it.' -ForegroundColor Green
    while (-not (Test-Path -LiteralPath $apiStopFile)) {
        if (-not $server.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $peer = $server.AcceptTcpClient()
        $stream = $peer.GetStream()
        $stream.ReadTimeout = 3000; $stream.WriteTimeout = 3000
        try {
            $header = New-Object Text.StringBuilder
            $deadline = [datetime]::UtcNow.AddSeconds(5)
            while ($header.Length -lt 32768 -and [datetime]::UtcNow -lt $deadline) {
                $b = $stream.ReadByte()
                if ($b -lt 0) { break }
                [void]$header.Append([char]$b)
                if ($header.ToString().EndsWith("`r`n`r`n")) { break }
            }
            $text = $header.ToString()
            $lines = $text -split "`r`n"
            $first = [regex]::Match($lines[0], '^([A-Z]+) ([^ ]+) HTTP/1\.[01]$')
            if (-not $text.EndsWith("`r`n`r`n") -or -not $first.Success) { Send-ApiResponse $stream 400 'bad_request'; continue }
            if ($first.Groups[2].Value -cne '/lab/data') { Send-ApiResponse $stream 404 'not_found'; continue }
            if ($first.Groups[1].Value -cne 'GET') { Send-ApiResponse $stream 405 'method'; continue }
            $headers = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
            $badHeaders = $false
            foreach ($line in $lines[1..($lines.Length-1)]) {
                if (-not $line) { break }
                $colon = $line.IndexOf(':')
                if ($colon -le 0 -or $line -match '^\s') { $badHeaders=$true; break }
                $name = $line.Substring(0,$colon)
                if ($name -notmatch '^[A-Za-z0-9-]+$' -or $headers.ContainsKey($name)) { $badHeaders=$true; break }
                $headers.Add($name, $line.Substring($colon+1).Trim())
            }
            if ($badHeaders -or -not $headers.ContainsKey('Host') -or
                @('127.0.0.1:8766','localhost:8766','host.docker.internal:8766') -notcontains $headers['Host'] -or
                $headers.ContainsKey('Transfer-Encoding') -or
                ($headers.ContainsKey('Content-Length') -and $headers['Content-Length'] -ne '0')) {
                Send-ApiResponse $stream 400 'bad_request'; continue
            }
            $token = ''
            if ($headers.ContainsKey('Authorization')) {
                $bearer = [regex]::Match($headers['Authorization'], '^(?i:Bearer) ([A-Za-z0-9_.-]+)$')
                if (-not $bearer.Success) { Send-ApiResponse $stream 401 'malformed_token' 'invalid_token'; continue }
                $token = $bearer.Groups[1].Value
            }
            if ($token -and [datetime]::UtcNow -ge $keysExpire) {
                try { $jwks=Get-PfSigningKeys; $keysExpire=[datetime]::UtcNow.AddMinutes(5) }
                catch { Send-ApiResponse $stream 503 'signing_keys_unavailable'; continue }
            }
            $decision = Get-AccessDecision $token $jwks
            Send-ApiResponse $stream $decision.Status $decision.Reason $decision.Error $decision.Subject
        } catch [System.IO.IOException] {
            Write-Host 'Local connection closed or timed out.'
        } catch {
            Send-ApiResponse $stream 400 'bad_request'
        } finally {
            $token=$null; $headers=$null; $text=$null
            $stream.Dispose(); $peer.Close()
        }
    }
    Write-Host 'API stopped by the lab shutdown request.'
} catch { Write-Host ('FAIL: ' + $_.Exception.Message) -ForegroundColor Red }
finally { if ($server) { $server.Stop() } }
