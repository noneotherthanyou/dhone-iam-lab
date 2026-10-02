# Directory recovery exercise

**Verified scope:** a saved `userRoot` backend was restored into an isolated instance, and authenticated LDAP checks found all 14 OUs, employee `employee01` with `EMP001`, Employees group membership, and `svc-pingfederate`.

The original v1.2 script successfully resumed a stopped recovery copy after the offline restore had completed. The earlier run timed out during orchestration even though the recovered server had started. The successful test removed its temporary container and volume.

This is not proof of full-system recovery. PF/PA configuration, every PD configuration setting, certificates, access-control behavior, and end-user authentication after restoration need separate tests.

## Required private recovery material

| Relative file/directory under the backup folder | Purpose |
|---|---|
| `containers.json` | Saved Docker metadata array identifying `/pingdirectory` and the exact image ID |
| `PingDirectory.lic` | Your authorized PD license |
| `pd-secrets/root-password` | Directory root password |
| `pd-secrets/encryption-password` | Saved encryption passphrase |
| `pingdirectory-native/encryption-settings.export` | Export of the required encryption definitions |
| `pingdirectory-native/backends/userRoot/backup.info` and backup files | Native backend backup |

These are private inputs, not repository contents. The exact recorded image must already be available locally. Full Docker metadata can contain credentials; never upload it as evidence. The original supplemental archive also retained runtime configuration and encryption metadata separately. Native backend backup alone does not replace those recovery materials.

## Run the public helper

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned `
  -File .\scripts\Dhone-PD-Restore-Test.ps1 `
  -BackupPath 'C:\YourPrivateLab\backups\YOUR-BACKUP'
```

If the metadata is elsewhere, add `-MetadataPath 'C:\YourPrivateLab\containers.json'`. These path parameters replace the original machine-specific defaults; **this public-copy change has not been rerun on Windows**.

The helper uses a dedicated volume and a container with no network or published ports, mounts the backup read-only, restores offline, starts the server, and checks entries through container-local LDAP. On failure it retains the stopped test copy for investigation. Resume is only for a compatible, labeled stopped recovery container after a completed restore; use `-ResumeContainer` with that precise name after reviewing its log.

Do not point manual restore commands at the active lab instance. Cleanup should target only the named recovery resources. Do not use broad volume pruning.

References: [PD restore tool](https://docs.ping.directory/PingDirectory/latest/cli/restore.html), [setup tool](https://docs.ping.directory/PingDirectory/latest/cli/setup.html).
