#requires -Version 5.1
# Run on the Windows lab PC while pingdirectory is healthy.
# Creates missing OUs only; then verifies all required OUs.
& {
    $pdBase = 'dc=dhone,dc=in'
    $pdOUs = @(
        'Employees', 'Admins', 'HR', 'StakeHolders', 'Customers',
        'Agents', 'Partners', 'Bots', 'AIAgents',
        'People', 'VIP', 'Guest', 'groups', 'services'
    )
    $pdOptions = @(
        '--noPropertiesFile', '--hostname', 'localhost', '--port', '1389',
        '--bindDN', 'cn=Directory Manager',
        '--bindPasswordFile', '/run/secrets/directory-root-password'
    )

    $pdBefore = @(docker --context desktop-linux exec pingdirectory /opt/out/instance/bin/ldapsearch @pdOptions --baseDN $pdBase --scope one '(objectClass=organizationalUnit)' ou)
    if ($LASTEXITCODE -ne 0) {
        $pdBefore
        throw 'Directory search failed. No OU additions were attempted.'
    }
    $pdExisting = @($pdBefore | Where-Object { $_ -match '^dn: ' } | ForEach-Object { $_.Substring(4).Trim() })
    $pdMissing = @($pdOUs | Where-Object { $pdExisting -notcontains "ou=$_,$pdBase" })

    if ($pdMissing.Count -gt 0) {
        $pdLdif = ($pdMissing | ForEach-Object {
            "dn: ou=$_,$pdBase`nchangetype: add`nobjectClass: top`nobjectClass: organizationalUnit`nou: $_`n"
        }) -join "`n"

        $pdLdif | docker --context desktop-linux exec -i pingdirectory /opt/out/instance/bin/ldapmodify @pdOptions
        if ($LASTEXITCODE -ne 0) {
            throw 'An OU add failed. Keep the error; earlier successful additions remain in place.'
        }
    }
    else {
        Write-Host 'All required OUs already exist.'
    }

    $pdAfter = @(docker --context desktop-linux exec pingdirectory /opt/out/instance/bin/ldapsearch @pdOptions --baseDN $pdBase --scope one '(objectClass=organizationalUnit)' ou)
    if ($LASTEXITCODE -ne 0) {
        $pdAfter
        throw 'The final directory search failed.'
    }
    $pdAfter
    $pdFound = @($pdAfter | Where-Object { $_ -match '^dn: ' } | ForEach-Object { $_.Substring(4).Trim() })
    $pdUnconfirmed = @($pdOUs | Where-Object { $pdFound -notcontains "ou=$_,$pdBase" })
    if ($pdUnconfirmed.Count -gt 0) {
        throw ('Required OUs missing from the result: ' + ($pdUnconfirmed -join ', '))
    }
    Write-Host 'Verified: 12 identity OUs plus groups and services.'
}
