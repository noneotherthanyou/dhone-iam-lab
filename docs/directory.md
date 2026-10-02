# Directory foundation and employee identity

Base DN: `dc=dhone,dc=in`. Container: `pingdirectory`. The existing root password is read from `/run/secrets/directory-root-password` inside the container.

## Population model

Create separate OUs for:

| Category | OU |
|---|---|
| Employees | `ou=Employees` |
| Administrators | `ou=Admins` |
| Human resources | `ou=HR` |
| Stakeholders | `ou=StakeHolders` |
| Customers | `ou=Customers` |
| Human agents | `ou=Agents` |
| Partners | `ou=Partners` |
| Bots | `ou=Bots` |
| AI agents | `ou=AIAgents` |
| General people | `ou=People` |
| VIP users | `ou=VIP` |
| Guests | `ou=Guest` |
| Groups | `ou=groups` |
| Service accounts | `ou=services` |

Append the base DN to each OU. OUs provide organization and search boundaries; they do not grant administrator rights. Treat Bots and AIAgents as workload identities when designing their eventual credentials and permissions.

## Create and verify the OUs

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Initialize-DhoneDirectoryOUs.ps1
```

The script searches first, adds only missing OUs, then verifies all 14. Its public copy explicitly selects `desktop-linux`.

## Add the fictional employee and group

After confirming the two sample entries do not already exist:

```powershell
Get-Content .\examples\directory\employee-and-group.ldif -Raw |
    docker --context desktop-linux exec -i pingdirectory /opt/out/instance/bin/ldapmodify `
      --noPropertiesFile --hostname localhost --port 1389 `
      --bindDN 'cn=Directory Manager' `
      --bindPasswordFile /run/secrets/directory-root-password
```

The fixture contains no password and is not idempotent. Set the employee password interactively:

```powershell
docker --context desktop-linux exec -it pingdirectory /opt/out/instance/bin/ldappasswordmodify `
  --noPropertiesFile --hostname localhost --port 1389 `
  --bindDN 'cn=Directory Manager' `
  --bindPasswordFile /run/secrets/directory-root-password `
  --userIdentity 'uid=employee01,ou=Employees,dc=dhone,dc=in' `
  --promptForNewPassword
```

Verify a bind as `employee01` using `--promptForBindPassword`, and independently query the Employees group's `member` attribute.

## PF service account and permissions

Use `uid=svc-pingfederate,ou=services,dc=dhone,dc=in` as the application bind identity. The recorded lab allowed the required employee identity attributes and group membership reads, and denied tested modifications to the employee, group and service entries.

The exact ACI export is intentionally not included in this snapshot. Rebuilding the directory requires creating and reviewing appropriate read permissions, then repeating the positive read and negative write probes. Do not use Directory Manager as PF's application bind identity. A successful anonymous search with zero returned entries is evidence for that query, not proof of every anonymous-access rule.

Connect PF to `pd.dhone.in:1636` on the shared Docker network. Trust the directory's actual certificate and validate its hostname. `localhost` inside the PF container refers to PF itself.
