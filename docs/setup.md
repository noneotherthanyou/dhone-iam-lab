# Lab setup and assumptions

This repository documents an existing incremental lab. It is not a one-command installation of every product.

## Recorded baseline

| Component | Lab value |
|---|---|
| Host | Windows with Windows PowerShell 5.1, Docker Desktop Linux engine |
| Lab resources | 16 GB host RAM; Docker approximately 9.7 GiB and 4 CPUs |
| Docker context | `desktop-linux`, local Windows named pipe |
| Docker bridge | `identitylab` |
| PingFederate | `pingidentity/pingfederate:13.1.3-alpine-flex` |
| PingDirectory | `pingidentity/pingdirectory:2607-11.1.0.0` |
| PingAccess | `pingidentity/pingaccess:2608-9.1.0` |
| PD memory | 2 GiB container limit; 1 GiB Java heap |
| PA memory | 3 GiB container limit |
| Local working data | `$env:USERPROFILE\DhoneLab` |

These are the versions used for the recorded POCs, not a claim that they are always the latest or available to every account.

## Endpoints

| Purpose | Local endpoint |
|---|---|
| PF administration | `https://localhost:9999` |
| PF runtime / local issuer | `https://localhost:9031` |
| PD LDAP / LDAPS | `localhost:1389` / `localhost:1636` |
| PD HTTPS | `https://localhost:1443` |
| PA administration | `https://localhost:9000` |
| PA gateway | `https://localhost:3000` |
| Desktop PKCE callback | `http://127.0.0.1:8765/callback` |
| Teaching API | `http://127.0.0.1:8766/lab/data` |

PD and PA host ports were published on loopback. The original PF publishes 9031/9999 on all interfaces; changing that requires a reviewed recreation plan after persistence/recovery is established. The compose example provided here only describes PD.

## Preparation

1. Obtain your own licenses and access to the applicable official product images. No license files are included.
2. Confirm the local Linux engine and its resources:

   ```powershell
   docker --context desktop-linux info
   docker --context desktop-linux ps --format 'table {{.Names}}\t{{.Status}}'
   ```

3. For a new lab only, create `identitylab` if it does not already exist. Existing lab users should retain their network and containers.
4. Configure PF using its product installation documentation, then follow [the federation settings](pingfederate-oidc.md). Establish persistent runtime data and backups before recreation.
5. For PD, review `examples/pingdirectory/compose.yaml`. Copy it to your private PD working folder. Its relative paths require `license/PingDirectory.lic`, `secrets/root-password`, `secrets/admin-password`, and `secrets/encryption-password`, each containing your own local input. Run Compose only after those files and the external network exist. Do not launch it against a conflicting existing `pingdirectory` container or volume.
6. For a new PA installation, review and run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-Install-PingAccess.ps1 -LicensePath 'C:\YourPrivateLab\PingAccess.lic'
   ```

   The helper refuses existing PA names/volumes and prompts locally for the administrator password. It accepts the product EULA as part of startup; run it only with an appropriate entitlement and acceptance of the terms.

## Certificate prerequisites

Create/export your own PF public server certificate with SANs for the names you use. The lab uses `localhost`, `pingfederate` and `pf.dhone.in`. Save its public PEM certificate or appropriate CA bundle at `$env:USERPROFILE\DhoneLab\certs\pf-runtime.pem`. Trust the appropriate certificate in Windows and in each product trust configuration. A trusted certificate with no matching SAN can still fail browser validation.

For PA's initial localhost certificate, the included helper supports:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-Trust-PingAccess.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\Dhone-Trust-PingAccess.ps1 -Endpoint Engine
```

## Lifecycle

Run `Dhone-Lab.ps1 Start -WithApi`, `Status` or `Stop` from `scripts/` or with the full script path. It manages existing PD, PF and optional PA containers; it does not create missing ones. The API and controller must remain in the same directory. Docker Desktop remains open after Stop.

See [publication notes](publication.md) for which helpers were exercised in the original Windows lab and which public-copy edits need revalidation.
