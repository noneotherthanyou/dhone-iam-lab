# Validation exercises

Run from the repository root in Windows PowerShell on the configured lab PC. Use only fictional accounts. Review downloaded scripts and unblock the files you intend to run if Windows marks them as downloaded.

## Local login and direct API

Start the existing containers and API:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-Lab.ps1 Start -WithApi
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-PKCE-Test.ps1 -Scope 'openid lab.read' -TestApi
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-PKCE-Test.ps1 -Scope 'openid' -TestApi
```

Sign in as `employee01` with the password set privately. These commands were observed passing in the original lab, with scripts located directly in the private working folder.

| Check | Expected result | Recorded result |
|---|---|---|
| OIDC authorization code + S256 | Successful exchange | PASS |
| State and nonce | Match the client's request | PASS |
| ID-token signature, issuer, audience, lifetime | Valid | PASS |
| No API token | 401, `missing_token` | PASS |
| ID token used at API | 401, `audience` | PASS |
| Tampered access token | 401, `signature` | PASS |
| Access token with `lab.read` | 200, `allowed` | PASS |
| Access token without `lab.read` | 403, `insufficient_scope` | PASS |

`401` means the request lacks acceptable authentication. `403` means an authenticated request lacks the required permission. The client prints status and selected claims, not bearer tokens. An intentionally wrong password was also reported rejected in the browser. An incorrect PKCE verifier and a real expired token have not yet been tested end to end.

## PingAccess gateway

After completing the configuration in [PingAccess](pingaccess.md), replace `-TestApi` with `-TestGateway`. Do not use both switches together.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-PKCE-Test.ps1 -Scope 'openid lab.read' -TestGateway
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-PKCE-Test.ps1 -Scope 'openid' -TestGateway
```

The same allow/deny outcomes are intended. **This POC is not passing yet:** valid tokens still returned a PA 401 challenge in the last supplied output. Every request being rejected does not prove that PA independently validated signature and audience. Resolve JWKS retrieval, obtain the positive 200, then repeat the negative tests.

## Recovery

The [isolated recovery exercise](recovery.md) verified restored directory entries in a temporary instance. It does not establish full-system recovery or recovery of PF and PA configuration.

Record evidence as a short result table with date, versions and scope. Do not commit headers, cookies, complete tokens, authorization codes, passwords or raw diagnostic archives.
