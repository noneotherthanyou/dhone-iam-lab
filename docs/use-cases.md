# IAM use-case roadmap

Each exercise should produce a configuration note, an allow result, a deny result, and a cleanup/recovery note. Product installation alone does not demonstrate an IAM control.

| Stage | POC | Status / completion evidence |
|---|---|---|
| Foundation | Separate 12 identity populations, groups and services | Verified: 14 OUs |
| Foundation | Employee account, password and group membership | Verified for fictional `employee01` |
| Directory | Least-privilege PF service reads | Verified for tested attributes; tested writes denied |
| Directory | LDAPS trust and hostname validation | Verified PF datastore connection |
| Federation | Employee login policy and contract mapping | Verified local OIDC login |
| Federation | Authorization Code with PKCE S256 | Verified successful exchange |
| Federation | State, nonce and signed ID-token validation | Verified |
| Authorization | JWT resource-server validation | Verified direct API allow/deny matrix |
| Authorization | Scope enforcement: `lab.read` | Verified 200 with scope, 403 without |
| Operations | Native backup integrity | Verified `userRoot` backup verification |
| Operations | Isolated data restore | Verified recovered entries; full recovery pending |
| Gateway | PA install, license and trusted HTTPS | Verified |
| Gateway | JWKS retrieval through PA's service configuration | In progress: actual fetch returned HTML/400 |
| Gateway | Valid token pass-through and scope rule | Pending positive 200 and negative retest |
| Public testing | Virtual issuer and external discovery | Verified public metadata |
| Public testing | Separate WebApp onboarding | User-reported success |
| MFA | Employee password plus authenticator TOTP | Planned; verify MFA entitlement first |
| MFA | Enrollment, invalid/expired code, recovery and reset | Planned; no seeds or QR codes in evidence |
| Federation | SAML SP-initiated SSO and signed assertions | Planned |
| Sessions | Logout, session lifetime and reauthentication | Planned |
| OAuth | Refresh tokens, rotation and revocation behavior | Planned; confirm supported configuration |
| OAuth | Wrong verifier, wrong redirect and expired-token tests | Planned; redirect rejection already observed during onboarding |
| Authorization | Group/role claims and population-specific policies | Planned; OU placement alone grants no role |
| Workloads | Bots and AI agents using scoped machine credentials | Planned; separate from interactive employee passwords |
| Lifecycle | Joiner, mover, leaver and disabled-user behavior | Planned |
| PingOne | Tenant setup, federation and MFA integration | Planned; included entitlement must be confirmed |
| DaVinci | Login orchestration, branching and failure handling | Planned; included entitlement must be confirmed |
| Operations | Key rotation, TLS renewal and monitoring | Planned |
| Operations | PF/PA full recovery and backend isolation | Planned |

## Next MFA exercise

Confirm an existing authorized PingOne MFA or PingID entitlement and the correct integration before changing the policy. An NFR license for an on-premises product does not, by itself, establish access to every cloud service. Do not start a paid service to complete this roadmap.

The intended employee path is password validation, then authenticator verification, then the existing success contract. Enrollment must follow authenticated identification; failed or cancelled MFA must not reach success. Preserve a tested administrative recovery path and exercise both enrolled and unenrolled fictional employees.

PingFederate includes supported adapter integrations, but the selected product, tenant and policy configuration still need verification. References: [bundled PF adapters](https://docs.pingidentity.com/pingfederate/13.1/introduction_to_pingfederate/pf_bundled_adapt_auth.html), [PingOne authenticator app](https://docs.pingidentity.com/pingone/strong_authentication_mfa/p1_strong_auth_configuring_authenticator_app.html).
