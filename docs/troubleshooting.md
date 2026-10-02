# Troubleshooting from the lab

| Symptom | What the evidence established | Next action |
|---|---|---|
| `podman` not recognized | Podman was unavailable; Docker Desktop worked | Use the documented Docker context; do not install another engine unnecessarily |
| PD license invalid | The supplied local license differed from the intended file | Verify the private source and mounted bytes; use a valid product license |
| LDAP 49 | Bind credentials were rejected | Re-enter privately; inspect account/password state if repeated |
| LDAP 50 during a service write probe | Tested write was denied | Expected for the read-only service; retain positive-read checks |
| No authentication methods available for OAuth | Authentication policy configuration was missing/incomplete | Save and enable the policy, successful contract path and grant mapping |
| No access token managers available | Client/authentication context lacked an eligible ATM | Check selected manager, restrictions and applicable mapping |
| Invalid `redirect_uri` | Requested callback did not match the registered client | Register the exact callback on the intended client; avoid wildcard workarounds |
| API `KeySize` is read-only | Earlier RSA setup was incompatible with Windows PowerShell | Use the updated API helper with `RSACng` construction |
| Backend 400 using `host.docker.internal` | Teaching API rejected that Host value | Updated API accepts the intended local backend Host |
| PA JWT parser sees `<` | JWKS fetch received HTML, not a key set | Compare actual PA request and PF response; see [gateway notes](pingaccess.md) |
| Certificate trusted but browser warns | Original certificate had no SAN | Issue a certificate with the required names; update trust deliberately |
| oauth.tools has no metadata for localhost | Its discovery service cannot reach the PC's localhost | Use the separate [public discovery exercise](public-discovery.md) |
| ngrok endpoint already online | Assigned endpoint was already in use | Identify/stop the existing tunnel; use the intended policy |
| Restore setup cannot resolve hostname | Isolated instance lacked a usable local hostname mapping | Current helper maps its isolated hostname and uses the setup options |
| Restore timeout but server log says started | Earlier orchestration blocked after starting the server | Current helper backgrounds startup, polls LDAP, and supports guarded resume |

PF's discovered log path in this lab is `/opt/pingidentity/runtime/log/server.log`. Do not assume the older `server/default/log/server.log` path exists. BusyBox `readlink -f` accepts one path per invocation in this image.

Keep diagnostics short and redact before sharing. Avoid broad Docker inspect output because environment variables may contain credentials. Do not disable certificate or audience validation to obtain a passing result.
