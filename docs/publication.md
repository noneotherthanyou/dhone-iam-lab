# Publication scope and review

This snapshot packages original lab helpers and documentation for a public source repository. It does not upload or host the running products. No licenses, product binaries, secret files, backups, certificates, account identifiers, live tunnel hostname or raw session transcript are included.

## Evidence boundaries

| Helper | Original lab evidence | Public snapshot changes |
|---|---|---|
| `Dhone-Lab.ps1` | Status showed all three containers healthy and API running | File organization only; full Start/Stop sequence not independently evidenced |
| `Dhone-PKCE-Test.ps1` | Local OIDC and direct API matrix passed | File organization only |
| `Dhone-Protected-API.ps1` | Direct API allow/deny checks passed | File organization only |
| `Dhone-Install-PingAccess.ps1` | PA healthy; license hash matched; console accepted license | File organization only |
| `Dhone-Trust-PingAccess.ps1` | Admin and engine TLS checks passed | File organization only |
| `Dhone-JWKS-Diagnostics.ps1` | curl HTTP/1.1 returned JWKS JSON; optional OpenSSL matrix skipped | File organization only |
| `Initialize-DhoneDirectoryOUs.ps1` | All 14 OUs verified | Added PowerShell version requirement and explicit Docker context |
| `Dhone-PD-Restore-Test.ps1` | Original v1.2 resumed a completed offline restore and verified entries | Required backup path and optional metadata path replace machine-specific defaults; labeled `v1.2-public` |

The public path/context edits have not been executed on the Windows lab PC. No PowerShell or Docker runtime is available in the publication workspace. Publication checks cover included files, relative documentation links, example syntax where tooling is available, and obvious private-data patterns. These checks do not replace end-to-end execution or guarantee that a future contributor cannot commit a secret.

The recipe is incremental, not a complete unattended bootstrap. Exact original ACI exports, PF/PA configuration exports and a full-system recovery procedure are not included. Their completion belongs on the [roadmap](use-cases.md).

## Cost and publishing

A normal public source repository is available on [GitHub Free](https://docs.github.com/en/get-started/learning-about-github/githubs-plans). This snapshot has no Actions workflow, Codespaces configuration, Git LFS or Packages upload. Local hardware, existing licensed products and optional external service entitlements remain separate from repository storage.

Publish only this clean project folder. Keep the private working lab elsewhere. Before every push, review `git diff --cached` and the staged file list. `.gitignore` is a convenience, not a security boundary: it does not remove data that was already tracked.

Do not upload a zip of the entire private lab. Public issues should contain synthetic examples and short sanitized result tables. See [security](../SECURITY.md) and [contribution guidance](../CONTRIBUTING.md).

No open-source license grant has been selected for this snapshot. Public visibility by itself does not grant unrestricted reuse rights. Vendor software and documentation remain governed by their respective terms.
