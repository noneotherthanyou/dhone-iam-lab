# PingAccess API gateway

Installation, license acceptance and trusted admin/engine TLS were verified. The gateway authorization POC remains incomplete.

## Recorded objects

| Object | Values |
|---|---|
| Third-party service | `Dhone-PF-JWKS` |
| Service target | `pingfederate:9031`, HTTPS |
| HTTP Host / expected certificate hostname | `localhost:9031` / `localhost` |
| Trusted certificate group | `Dhone-PF-Trust`, containing the current PF runtime trust material |
| Service options | No proxy; hostname validation enabled |
| Access validation | `Dhone-PF-JWT`, JSON Web Key Set endpoint |
| JWKS path | `/pf/JWKS`, through `Dhone-PF-JWKS` |
| Subject / issuer / audience | `sub` / `https://localhost:9031` / `urn:dhone:lab:api` |
| Skip audience validation | False |
| Backend site | `Dhone-Lab-API-Backend`, `host.docker.internal:8766`, HTTP |
| Backend options | Use target Host header; send the access token |
| Application | `Dhone-Lab-API`, API type, context root `/lab`, virtual host `localhost:3000`, enabled |
| Rule | `Dhone-Lab-Read`, OAuth Groovy API rule using `hasScopes("lab.read")`; denial status 403 |

Attach the validator and scope rule to the application/resource that handles `/lab/data`. The teaching backend also validates the token. Do not remove that validation to make a gateway test pass.

The HTTP backend leg is a local teaching configuration. Backend TLS and preventing direct backend access remain separate exercises. Inside a container, `localhost` means that container; Docker's `host.docker.internal` reaches the Windows host.

## Current failure and next diagnostic

The PA log reported an unexpected `<` while parsing the JWKS response. PF's request log showed PA's `/pf/JWKS` requests receiving HTTP 400. A separate curl request from inside PA, with the intended TLS name and Host, returned HTTP 200 and JSON, including with HTTP/1.1.

That establishes a difference between the actual PA request and the successful diagnostic request. It does not establish that the signing key is absent, that HTTP/1.1 is broken, or that the scope rule is at fault.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-JWKS-Diagnostics.ps1
```

Check the current service target, Host, certificate hostname and trust group against the table. After any certificate replacement, update PA's trust material deliberately. Compare a fresh PA failure with the corresponding PF request before changing configuration. Keep TLS verification enabled. Only rerun the login matrix after a concrete adjustment or new diagnostic finding.

Reference: [OAuth Groovy Script rules](https://docs.pingidentity.com/pingaccess/9.1/pingaccess_user_interface_reference_guide/pa_adding_oauth_groovy_script_rules.html).
