<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Administration

These verbs use APIs Synology does not document (`SYNO.Core.*`,
`SYNO.Storage.CGI.Storage`); the deck sends what the DSM web interface and
established clients send. The account needs to be an administrator.

## Health

```jennifer
def u as synology.Utilization init synology.utilization($c);
io.printf("CPU %d percent, memory %d percent\n", $u.cpuPercent, $u.memoryPercent);
for (def v in synology.volumes($c)) {
    io.printf("%s %s %d of %d bytes\n", $v.path, $v.status, $v.usedBytes, $v.totalBytes);
}
for (def d in synology.disks($c)) {
    if ($d.smartStatus != "normal" or $d.status != "normal") {
        io.printf("check %s (%s): %s, SMART %s\n", $d.name, $d.model, $d.status, $d.smartStatus);
    }
}
```

## Certificates

Deploying a renewed certificate, for example from an ACME client:

```jennifer
def key as bytes init fs.readBytes("privkey.pem");
def pem as bytes init fs.readBytes("cert.pem");
for (def cert in synology.certificates($c)) {
    if ($cert.commonName == "nas.example.com") {
        synology.importCertificate($c, $key, $pem, fs.readBytes("chain.pem"), "", $cert.id, false);
    }
}
```

`importCertificate` with a `replaceId` renews that certificate in place, so
the services using it keep it. Without one it adds a new certificate;
`assignCertificate` then hands a service to it, by the name DSM shows
(`DSM Desktop Service`, `FTPS`, ...). DSM restarts its web server, and the
next request may fail once while it does.

## Updates and power

```jennifer
def up as synology.DsmUpdate init synology.checkUpdate($c);
if ($up.available) {
    io.printf("%s is available (reboot: %s)\n", $up.version, $up.reboot);
}
synology.reboot($c);
```

`reboot` and `shutdown` end the session.

## Packages and services

```jennifer
for (def p in synology.packages($c)) {
    io.printf("%s %s %s\n", $p.id, $p.version, $p.status);
}
synology.stopPackage($c, "ContainerManager");
synology.setService($c, "ssh", false);
```

`setService` knows `ssh`, `smb` and `nfs`; it sends only the on/off flag,
so ports and other settings stay as they are.
