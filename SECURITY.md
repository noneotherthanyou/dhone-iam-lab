# Security and data handling

Use fictional users and data. Keep the teaching API on loopback, and maintain TLS, hostname, JWT signature, issuer, audience, expiry and scope validation.

## What must stay out of Git

- Ping license files and signatures; vendor installation archives and image exports.
- Passwords, client secrets, access/ID/refresh tokens, authorization codes and PKCE verifiers.
- ngrok authtokens and live tunnel addresses.
- TOTP enrollment QR codes, shared seeds and recovery codes.
- Private keys, exported keystores, user data, database files and backup encryption material.
- Full Docker inspect output or raw PF/PA configuration exports, which can contain credentials.

The PingAccess installer passes its administrator password through the process environment. Docker retains the value in container metadata. Use narrowly formatted status and mount queries when collecting evidence.

The certificate helper intentionally imports a verified local lab certificate into the current Windows user's root store. Run it only against your own local containers after reviewing its output and source.

## Sharing results

Share status tables and the smallest sanitized error needed to reproduce an issue. Keep real names, organization identifiers and account addresses out of screenshots. Do not open an issue containing credentials. If a secret is exposed, revoke or rotate it through the relevant product; removing it from a later commit does not remove it from earlier history.

## Boundaries

OU placement is not authorization. LDAP ACIs, group membership, authentication policies and resource-server rules establish the relevant access controls.

The bundled API is a small single-process teaching server. Its custom token parser and HTTP handling are intended for these local POCs. Use maintained security libraries and a reviewed architecture for a production application.

The gateway's valid-token path and backend-bypass protection remain unverified. Do not interpret a 401 for every request as proof that its individual token checks work.
