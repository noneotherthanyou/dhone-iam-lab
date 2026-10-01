#requires -Version 5.1
<#
Dhone lab public-client OIDC test. Run with Windows PowerShell 5.1.
Uses curl.exe and .NET; no modules, client secret, or additional installs.
PF TLS trust comes from the previously retrieved PF runtime certificate.
-TestGateway uses Windows certificate trust established by Dhone-Trust-PingAccess.ps1 -Endpoint Engine.
Tokens stay in memory. This teaching client is not a production OIDC SDK.
References:
https://docs.pingidentity.com/pingfederate/13.1/developers_reference_guide/pf_authorization_endpoint.html
https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
https://docs.pingidentity.com/pingaccess/9.1/pingaccess_user_interface_reference_guide/pa_adding_oauth_groovy_script_rules.html
#>
[CmdletBinding()]
param(
    [string]$CertificatePath = (Join-Path $env:USERPROFILE 'DhoneLab\certs\pf-runtime.pem'),
    [ValidateRange(60,1800)][int]$TimeoutSeconds = 600,
    [ValidateSet('openid', 'openid lab.read')][string]$Scope = 'openid',
    [switch]$TestApi,
    [switch]$TestGateway
)

$ErrorActionPreference = 'Stop'
$issuer = 'https://localhost:9031'
$clientId = 'dhone-desktop-pkce'
$redirectUri = 'http://127.0.0.1:8765/callback'
$listener = $null
$tokens = $null
$verifier = $null
$code = $null
$savedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
$testFailed = $false

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertFrom-Base64Url([string]$Value) {
    if ($Value -cnotmatch '^[A-Za-z0-9_-]+$' -or $Value.Length % 4 -eq 1) {
        throw 'Invalid base64url value.'
    }
    $text = $Value.Replace('-','+').Replace('_','/')
    $text += '=' * ((4 - $text.Length % 4) % 4)
    return ,([Convert]::FromBase64String($text))
}

function New-RandomValue {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes); ConvertTo-Base64Url $bytes }
    finally { $rng.Dispose() }
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ,($sha.ComputeHash($Bytes)) }
    finally { $sha.Dispose() }
}

function ConvertTo-Form($Values) {
    ($Values.GetEnumerator() | ForEach-Object {
        [Uri]::EscapeDataString([string]$_.Key) + '=' +
        [Uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
}

function Invoke-LabJson([string]$Url, [string]$Label, [string]$Form = '') {
    if (@("$issuer/.well-known/openid-configuration", "$issuer/as/token.oauth2", "$issuer/pf/JWKS") -cnotcontains $Url) {
        throw 'Refusing an unexpected endpoint.'
    }
    $curlArgs = @('--disable', '--silent', '--show-error', '--proto', '=https',
        '--noproxy', 'localhost', '--connect-timeout', '10', '--max-time', '30',
        '--cacert', $CertificatePath, '--write-out', "`n%{http_code}")
    if ($Form) {
        # --data @- reads stdin and strips the PowerShell pipe's trailing CR/LF.
        # Authorization code and verifier are never placed on the command line.
        $raw = @($Form | & $script:curlPath @curlArgs '--data' '@-' $Url)
    } else {
        $raw = @(& $script:curlPath @curlArgs $Url)
    }
    if ($LASTEXITCODE -ne 0) { throw "$Label HTTPS request failed; see the curl error above." }
    $text = $raw -join "`n"
    $split = $text.LastIndexOf("`n")
    if ($split -lt 0) { throw "$Label returned an incomplete response." }
    $status = [int]$text.Substring($split + 1)
    try { $result = $text.Substring(0, $split) | ConvertFrom-Json }
    catch { throw "$Label returned non-JSON data (HTTP $status)." }
    if ($status -ne 200) {
        $safeError = 'request_failed'
        if ([string]$result.error -cmatch '^[a-z_]{1,60}$') { $safeError = [string]$result.error }
        throw "$Label failed: HTTP $status ($safeError)."
    }
    return $result
}

function Send-LocalResponse($Stream, [int]$Status, [string]$Message) {
    $body = [Text.Encoding]::UTF8.GetBytes($Message)
    $reason = if ($Status -eq 200) { 'OK' } else { 'Bad Request' }
    $header = [Text.Encoding]::ASCII.GetBytes(
        "HTTP/1.1 $Status $reason`r`nContent-Type: text/plain; charset=utf-8`r`n" +
        "Cache-Control: no-store`r`nReferrer-Policy: no-referrer`r`n" +
        "X-Content-Type-Options: nosniff`r`nConnection: close`r`nContent-Length: $($body.Length)`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Receive-AuthorizationCode($Server, [string]$ExpectedState, [datetime]$Deadline) {
    while ([datetime]::UtcNow -lt $Deadline) {
        if (-not $Server.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $peer = $Server.AcceptTcpClient()
        $stream = $peer.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        try {
            # Read only the bounded HTTP header; no callback URLs are logged.
            $header = New-Object Text.StringBuilder
            while ($header.Length -lt 16384) {
                $next = $stream.ReadByte()
                if ($next -lt 0) { break }
                [void]$header.Append([char]$next)
                if ($header.ToString().EndsWith("`r`n`r`n")) { break }
            }
            $request = $header.ToString()
            $requestMatch = [regex]::Match($request, '^GET (/[^ ]*) HTTP/1\.[01]\r\n')
            if (-not $request.EndsWith("`r`n`r`n") -or -not $requestMatch.Success) {
                Send-LocalResponse $stream 400 'Invalid callback request.'
                continue
            }
            $target = [Uri]('http://127.0.0.1:8765' + $requestMatch.Groups[1].Value)
            if ($target.AbsolutePath -cne '/callback') {
                Send-LocalResponse $stream 400 'Use the login opened by the PowerShell client.'
                continue
            }
            $query = New-Object 'Collections.Generic.Dictionary[string,string]'
            $duplicate = $false
            foreach ($part in $target.Query.TrimStart('?').Split('&')) {
                if (-not $part) { continue }
                $pair = $part.Split([char[]]'=', 2)
                $name = [Uri]::UnescapeDataString($pair[0].Replace('+',' '))
                $value = if ($pair.Length -gt 1) { [Uri]::UnescapeDataString($pair[1].Replace('+',' ')) } else { '' }
                if ($query.ContainsKey($name)) { $duplicate = $true; break }
                $query.Add($name, $value)
            }
            if ($duplicate -or -not $query.ContainsKey('state') -or $query['state'] -cne $ExpectedState) {
                Send-LocalResponse $stream 400 'Callback state check failed. Continue the original login.'
                continue
            }
            if ($query.ContainsKey('iss') -and $query['iss'] -cne $issuer) {
                Send-LocalResponse $stream 400 'Unexpected authorization response issuer.'
                throw 'Authorization response issuer mismatch.'
            }
            if ($query.ContainsKey('error')) {
                Send-LocalResponse $stream 400 'PingFederate declined this request. Check PowerShell.'
                $safeError = 'authorization_failed'
                if ($query['error'] -cmatch '^[a-z_]{1,60}$') { $safeError = $query['error'] }
                throw "Authorization failed ($safeError)."
            }
            if (-not $query.ContainsKey('code') -or -not $query['code']) {
                Send-LocalResponse $stream 400 'No authorization code received.'
                throw 'The callback contained no authorization code.'
            }
            Send-LocalResponse $stream 200 'Callback received. Close this tab and check the validation result in PowerShell.'
            return $query['code']
        } catch [System.IO.IOException] {
            # A disconnected or incomplete local request must not cancel login.
            continue
        } finally {
            $stream.Dispose()
            $peer.Close()
        }
    }
    throw 'Login timed out. Run the script again to start a fresh request.'
}

function Confirm-IdToken([string]$Token, $Jwks, [string]$ExpectedNonce, [string]$AccessToken) {
    $parts = $Token.Split('.')
    if ($parts.Length -ne 3) { throw 'Expected a signed, three-part ID token.' }
    try {
        $jwtHeader = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[0])) | ConvertFrom-Json
        $claims = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1])) | ConvertFrom-Json
    } catch { throw 'Malformed ID token.' }
    if ($jwtHeader.alg -cne 'RS256' -or $null -ne $jwtHeader.crit) {
        throw 'Unsupported ID token algorithm or critical headers.'
    }
    $keys = @($Jwks.keys | Where-Object {
        $_.kty -ceq 'RSA' -and (-not $_.use -or $_.use -ceq 'sig') -and
        (-not $_.alg -or $_.alg -ceq 'RS256') -and
        (-not $_.key_ops -or @($_.key_ops) -ccontains 'verify') -and
        (-not $jwtHeader.kid -or $_.kid -ceq $jwtHeader.kid)
    })
    if ($keys.Count -ne 1) { throw 'Could not select exactly one RS256 signing key from PF JWKS.' }
    $parameters = New-Object Security.Cryptography.RSAParameters
    $parameters.Modulus = ConvertFrom-Base64Url $keys[0].n
    $parameters.Exponent = ConvertFrom-Base64Url $keys[0].e
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportParameters($parameters)
        if ($rsa.KeySize -lt 2048) { throw 'ID token signing key is below 2048 bits.' }
        $valid = $rsa.VerifyData([Text.Encoding]::ASCII.GetBytes($parts[0] + '.' + $parts[1]),
            (ConvertFrom-Base64Url $parts[2]), [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $valid) { throw 'ID token signature verification failed.' }
    } finally { $rsa.Dispose() }
    if ($claims.iss -cne $issuer) { throw 'ID token issuer mismatch.' }
    $audiences = @($claims.aud)
    if ($audiences -cnotcontains $clientId) { throw 'ID token audience mismatch.' }
    if (($audiences.Count -gt 1 -and -not $claims.azp) -or
        ($claims.azp -and $claims.azp -cne $clientId)) { throw 'ID token authorized-party mismatch.' }
    if ([string]::IsNullOrWhiteSpace([string]$claims.sub)) { throw 'ID token subject is missing.' }
    if ($claims.nonce -cne $ExpectedNonce) { throw 'ID token nonce mismatch.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($name in @('exp','iat')) {
        if ($claims.$name -isnot [long] -and $claims.$name -isnot [int]) { throw "ID token $name is missing or not an integer." }
    }
    if ($claims.exp -le ($now - 60) -or $claims.iat -gt ($now + 60) -or
        $claims.exp -le $claims.iat -or $claims.iat -lt ($now - $TimeoutSeconds - 60)) {
        throw 'ID token lifetime check failed. Check the PC and PF clocks.'
    }
    if ($null -ne $claims.nbf) {
        if (($claims.nbf -isnot [long] -and $claims.nbf -isnot [int]) -or $claims.nbf -gt ($now + 60)) {
            throw 'ID token not-before check failed.'
        }
    }
    if ($claims.at_hash) {
        $digest = Get-Sha256 ([Text.Encoding]::ASCII.GetBytes($AccessToken))
        if ($claims.at_hash -cne (ConvertTo-Base64Url ([byte[]]$digest[0..15]))) {
            throw 'ID token access-token hash mismatch.'
        }
    }
    return $claims
}

function Invoke-LabApi([string]$BearerToken = '') {
    # This HTTP endpoint is deliberately fixed to loopback for the local lab.
    # Tokens stay in memory; neither redirects nor a system proxy are allowed.
    $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:8766/lab/data')
    $request.Method = 'GET'; $request.Proxy = $null; $request.AllowAutoRedirect = $false
    $request.Timeout = 10000; $request.ReadWriteTimeout = 10000; $request.KeepAlive = $false
    if ($BearerToken) { $request.Headers['Authorization'] = 'Bearer ' + $BearerToken }
    $response = $null
    try {
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response }
            else { throw 'Local API is not reachable. Start Dhone-Protected-API.ps1 in a second PowerShell window.' }
        }
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $body = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        if ($body.api -cne 'dhone-lab-v1') { throw 'Unexpected response from the local API port.' }
        return [pscustomobject]@{Status=[int]$response.StatusCode; Body=$body}
    } finally { if ($response) { $response.Close() } }
}

function Test-ApiCase([string]$Name, [string]$Token, [int]$ExpectedStatus, [string]$ExpectedReason) {
    $result = Invoke-LabApi $Token
    $reason = [string]$result.Body.reason
    if ($reason -cnotmatch '^[a-z_]{1,40}$') { $reason = 'unexpected_response' }
    [pscustomobject]@{Test=$Name; Expected=$ExpectedStatus; Actual=$result.Status; Reason=$reason;
        Pass=($result.Status -eq $ExpectedStatus -and $reason -ceq $ExpectedReason)}
}

function Invoke-LabGateway([string]$BearerToken = '') {
    # Fixed HTTPS gateway URL, normal Windows TLS validation, no redirects/proxy.
    # Never put bearer tokens on a command line, in a file, or in shared output.
    $request = [Net.HttpWebRequest]::Create('https://localhost:3000/lab/data')
    $request.Method = 'GET'; $request.Proxy = $null; $request.AllowAutoRedirect = $false
    $request.Timeout = 15000; $request.ReadWriteTimeout = 15000; $request.KeepAlive = $false
    if ($BearerToken) { $request.Headers['Authorization'] = 'Bearer ' + $BearerToken }
    $response = $null
    try {
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response }
            else { throw 'Gateway HTTPS request failed. Check PingAccess health and Engine certificate trust.' }
        }
        $reader = [IO.StreamReader]::new($response.GetResponseStream())
        try {
            $buffer = New-Object char[] 65537
            $count = 0
            while ($count -lt $buffer.Length) {
                $read = $reader.Read($buffer, $count, $buffer.Length - $count)
                if ($read -eq 0) { break }
                $count += $read
            }
            if ($count -gt 65536) { throw 'Gateway response exceeded the 64 KiB test limit.' }
            $text = [string]::new($buffer, 0, $count)
        } finally { $reader.Dispose() }
        $json = $null
        if ($text.TrimStart().StartsWith('{')) {
            try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        }
        $backend = $null -ne $json -and $json.api -ceq 'dhone-lab-v1'
        $challenge = [string]$response.Headers['WWW-Authenticate']
        $paChallenge = ($challenge -imatch '^Bearer\s') -and
            ($challenge -cmatch '(?:^|[ ,])realm="localhost:3000/lab"(?:,|$)')
        $html = ([string]$response.ContentType -imatch '^text/html(?:\s*;|$)') -and
            ($text -imatch '<(?:!doctype\s+html|html)(?:\s|>)')
        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            Body = $json
            Backend = $backend
            PaChallenge = $paChallenge
            HtmlError = $html
        }
    } finally { if ($response) { $response.Close() } }
}

function Test-GatewayCase([string]$Name, [string]$Token, [int]$ExpectedStatus, [string]$ExpectedSubject = '') {
    $result = Invoke-LabGateway $Token
    $responseKind = 'unrecognized'
    $behavior = $false
    if ($result.Backend) {
        $responseKind = 'backend_json'
        if ($ExpectedStatus -eq 200) {
            $behavior = $result.Body.reason -ceq 'allowed' -and $result.Body.subject -ceq $ExpectedSubject
        }
    } elseif ($result.Status -eq 401 -and $result.PaChallenge) {
        $responseKind = 'PA_challenge'
        $behavior = $ExpectedStatus -eq 401
    } elseif ($result.HtmlError) {
        # With the configured Basic 403 template, a gateway HTML rejection is
        # distinguishable from this backend, which only emits JSON responses.
        $responseKind = 'gateway_error_page'
        $behavior = $ExpectedStatus -eq 403
    }
    [pscustomobject]@{
        Test = $Name; Expected = $ExpectedStatus; Actual = $result.Status
        Response = $responseKind
        Pass = ($result.Status -eq $ExpectedStatus -and $behavior)
    }
}

try {
    if ($TestApi -and $TestGateway) { throw 'Choose -TestApi or -TestGateway for this run, not both.' }
    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw "PF certificate not found: $CertificatePath"
    }
    $script:curlPath = (Get-Command curl.exe -CommandType Application -ErrorAction Stop).Source
    if ($TestApi) {
        $preflight = Invoke-LabApi
        if ($preflight.Status -ne 401 -or $preflight.Body.reason -cne 'missing_token') {
            throw 'API preflight failed: an unauthenticated request must return 401/missing_token.'
        }
    }
    if ($TestGateway) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $preflight = Test-GatewayCase 'Gateway preflight' '' 401
        if (-not $preflight.Pass) {
            $preflight | Format-Table -AutoSize
            throw 'Gateway preflight did not return the expected PingAccess 401 challenge. Share this table.'
        }
        Write-Host '[Gateway] HTTPS and PingAccess anonymous rejection verified; starting login.'
    }
    Write-Host '[1/5] Checking discovery over trusted HTTPS...'
    $discovery = Invoke-LabJson "$issuer/.well-known/openid-configuration" 'Discovery'
    $expected = @{ issuer = $issuer; authorization_endpoint = "$issuer/as/authorization.oauth2";
        token_endpoint = "$issuer/as/token.oauth2"; jwks_uri = "$issuer/pf/JWKS" }
    foreach ($name in $expected.Keys) {
        if ($discovery.$name -cne $expected[$name]) { throw "Unexpected discovery $name; review the PF settings." }
    }
    $verifier = New-RandomValue
    $challenge = ConvertTo-Base64Url (Get-Sha256 ([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state = New-RandomValue
    $nonce = New-RandomValue
    $authorization = ConvertTo-Form ([ordered]@{client_id=$clientId; response_type='code';
        redirect_uri=$redirectUri; scope=$Scope; code_challenge=$challenge;
        code_challenge_method='S256'; state=$state; nonce=$nonce; prompt='login'; login_hint='employee01'})
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), 8765)
    $listener.Start()
    Write-Host '[2/5] Opening login. Sign in as employee01; approve access if prompted.'
    Start-Process -FilePath ($discovery.authorization_endpoint + '?' + $authorization)
    $code = Receive-AuthorizationCode $listener $state ([datetime]::UtcNow.AddSeconds($TimeoutSeconds))
    $listener.Stop()
    Write-Host '[3/5] State verified. Exchanging the code using PKCE S256...'
    $form = ConvertTo-Form ([ordered]@{grant_type='authorization_code'; client_id=$clientId;
        redirect_uri=$redirectUri; code=$code; code_verifier=$verifier})
    $tokens = Invoke-LabJson $discovery.token_endpoint 'Token endpoint' $form
    $form = $null; $code = $null; $verifier = $null
    if (-not $tokens.id_token -or -not $tokens.access_token -or $tokens.token_type -ine 'Bearer') {
        throw 'Token response must contain an ID token and a Bearer access token.'
    }
    Write-Host '[4/5] Checking the ID token against PF signing keys...'
    $jwks = Invoke-LabJson $discovery.jwks_uri 'JWKS endpoint'
    $claims = Confirm-IdToken $tokens.id_token $jwks $nonce $tokens.access_token
    # RFC 6749 section 5.1: scope may be omitted when unchanged from the request.
    $grantedScopes = if ($null -ne $tokens.scope) { [string]$tokens.scope } else { $Scope }
    Write-Host '[5/5] PASS - Employee OIDC login completed and ID token validated.' -ForegroundColor Green
    [pscustomobject]@{
        Result = 'PASS'; Client = $clientId; Subject = $claims.sub; Issuer = $claims.iss
        IDTokenAudience = @($claims.aud) -join ', '; Signature = 'RS256 verified'
        PKCE = 'S256'; State = 'Verified'; Nonce = 'Verified'; Lifetime = 'Valid (60s clock tolerance)'
        AccessTokenReceived = $true
        RequestedScopes = $Scope
        GrantedScopes = $grantedScopes
        AccessTokenValidation = if ($TestGateway) { 'PingAccess gateway checks follow below' } elseif ($TestApi) { 'API checks follow below' } else { 'Not performed; use -TestApi or -TestGateway' }
    } | Format-List
    if ($TestApi -or $TestGateway) {
        $parts = $tokens.access_token.Split('.')
        if ($parts.Length -ne 3) { throw 'The API POC requires a JWT access token.' }
        $signature = ConvertFrom-Base64Url $parts[2]
        $signature[0] = $signature[0] -bxor 1
        $parts[2] = ConvertTo-Base64Url $signature
        $tampered = $parts -join '.'
        $expectRead = @($Scope.Split(' ')) -ccontains 'lab.read'
        if ($TestGateway) {
            $tests = @(
                Test-GatewayCase 'No token' '' 401
                Test-GatewayCase 'ID token as API token' $tokens.id_token 401
                Test-GatewayCase 'Tampered access token' $tampered 401
                if ($expectRead) { Test-GatewayCase 'Access token with lab.read' $tokens.access_token 200 $claims.sub }
                else { Test-GatewayCase 'Access token without lab.read' $tokens.access_token 403 }
            )
        } else {
            $tests = @(
                Test-ApiCase 'No token' '' 401 'missing_token'
                Test-ApiCase 'ID token as API token' $tokens.id_token 401 'audience'
                Test-ApiCase 'Tampered access token' $tampered 401 'signature'
                if ($expectRead) { Test-ApiCase 'Access token with lab.read' $tokens.access_token 200 'allowed' }
                else { Test-ApiCase 'Access token without lab.read' $tokens.access_token 403 'insufficient_scope' }
            )
        }
        $tests | Format-Table -AutoSize
        if (@($tests | Where-Object { -not $_.Pass }).Count -gt 0) {
            throw 'An allow/deny check failed. Share the result table, not tokens.'
        }
        if ($TestGateway) {
            Write-Host '[Gateway] PASS - All four PingAccess gateway checks matched expectations.' -ForegroundColor Green
        } else {
            Write-Host '[API] PASS - All four resource-server checks matched expectations.' -ForegroundColor Green
        }
    }
} catch {
    $testFailed = $true
    Write-Host ('FAIL: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($listener) { $listener.Stop() }
    $tokens = $null; $code = $null; $verifier = $null; $form = $null; $tampered = $null; $parts = $null
    [Net.ServicePointManager]::SecurityProtocol = $savedSecurityProtocol
}
if ($testFailed) { exit 1 }
