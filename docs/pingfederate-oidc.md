# Employee OIDC and PKCE

This is the recorded local configuration. Save each wizard and the containing policy before testing. The public tunnel exercise uses a separate client and virtual issuer; the desktop test below continues to use the local issuer.

## LDAP authentication

| Object | Configuration |
|---|---|
| LDAP datastore | `Dhone-PingDirectory-LDAPS`; `pd.dhone.in:1636`; TLS with certificate trust and hostname validation |
| Bind identity | `uid=svc-pingfederate,ou=services,dc=dhone,dc=in`; enter its password privately |
| Password credential validator | `DhoneEmployeesPCV`, LDAP Username Password Credential Validator |
| Search base | `ou=Employees,dc=dhone,dc=in` |
| Search filter | `(&(objectClass=inetOrgPerson)(uid=${username}))` |
| Search scope | Subtree |
| Detailed PingDirectory password policy messaging | Disabled for this first POC |
| HTML Form adapter | `DhoneEmployeesHTML`, using the employee PCV |
| Authentication policy | `Dhone Employees Login Policy`, enabled for OAuth |
| Successful policy outcome | `DhoneEmployeesContract` |

Expose the attributes required for fulfillment through the PCV and adapter. Map the contract `subject` from the directory DN; map `uid`, `displayName`, `employeeNumber`, and `employeeType` from the authenticated adapter attributes. Leave unsuccessful authentication on a failure path. The sample employee has no `mail` value, so do not require it for this POC.

## OAuth and OpenID Connect

| Object | Configuration |
|---|---|
| Base URL / local issuer | `https://localhost:9031` |
| Policy contract grant mapping | `USER_KEY` ← contract `subject`; `USER_NAME` ← contract `uid` |
| Access token manager | `DhoneLabJWT`, JWT, RS256, 10-minute token lifetime |
| Access token issuer / audience | `https://localhost:9031` / `urn:dhone:lab:api` |
| Access token mapping | `sub` ← persistent grant `USER_KEY` |
| OIDC policy | `DhoneEmployeesOIDC`, five-minute ID token; `sub` ← access token `sub` |
| Client ID | `dhone-desktop-pkce` |
| Client authentication | None: public desktop client |
| Grant / PKCE | Authorization Code; require PKCE; use S256 |
| Redirect URI | Exactly `http://127.0.0.1:8765/callback` |
| Allowed scopes | `openid` and `lab.read` |
| ID-token signing | RS256 |

Select the intended OIDC policy and token manager for the client. If token-manager access is restricted, include this client in its eligibility configuration. Configure the policy-contract-to-ATM mapping as well as the grant mapping; they have different purposes.

Before login, confirm discovery advertises the expected local issuer, authorization endpoint, token endpoint and JWKS URI. Then follow [validation](validation.md).

The ID token is for the client. The access token is for the API. Their audiences differ. A directory DN is sufficient for this small POC's subject but changes on a rename or move; a stable opaque subject is a later design exercise.

References: [OAuth clients](https://docs.pingidentity.com/pingfederate/13.1/administrators_reference_guide/pf_configuring_oauth_clients.html), [access token mappings](https://docs.pingidentity.com/pingfederate/13.1/administrators_reference_guide/pf_managing_access_token_mappings.html), [authorization endpoint](https://docs.pingidentity.com/pingfederate/13.1/developers_reference_guide/pf_authorization_endpoint.html).
