<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/synology

A client for the [Synology DSM](https://www.synology.com/dsm) Web API. `call`
reaches any API under `/webapi` and returns the reply's `data` as a
`json.Value`. Typed verbs cover logging in (with 2-step verification and
trusted devices), the system summary, File Station (shared folders,
listing, creating, renaming, copying, moving and deleting, upload and
download), Virtual Machine Manager (images, creating, powering and resizing
virtual machines), local users, groups and shared folders with their
permissions, and administration: certificates, snapshots, health, DSM
updates, power, packages, services, the Task Scheduler and Hyper Backup;
and Container Manager: containers, images and Compose projects.

**Infrastructure as Code (IaC).** Users, groups, shared folders and their
permissions, services, virtual machines and Compose projects can be
provisioned from a Jennifer program kept in version control and reviewed like
any other code. The create verbs are not idempotent: `createUser`,
`createShare`, `createGuest` and `createProject` fail when the name exists. A
re-runnable script lists what exists first (`users`, `shares`, `guests`,
`projects`); `setUserPassword`, `setSharePermission` and `setService` can be
applied again. There is no plan or diff step, and the deck does not detect
drift.

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/synology/" as synology;

def c as synology.Client init synology.client("nas.example.com");
$c = synology.login($c, "backup", "secret");
io.printf("%s\n", synology.info($c).version);
```

A `Client` is a value. `login`, `discover` and the `with*` functions return a
changed copy, so assign the result back to `$c`.

File Station paths start with the shared folder: `/photo/2024/a.jpg`, not
`/volume1/photo/2024/a.jpg`. `shares` gives both.

## Errors

Every failure is a `synology.SynologyError` (kind `"synology"`). The message
names the API and method, and translates DSM's numeric code; the code itself
is the `code` field (0 when DSM gave none), and an HTTP status other than 2xx
is the `status` field:

```text
synology: SYNO.FileStation.List getinfo: /photo/b.jpg: no such file or directory (code 408)
synology: SYNO.API.Auth login: 2-step verification code required (code 403); use loginOtp
synology: SYNO.DSM.Info getinfo: session timeout (code 106); log in again
```

Codes from 400 up mean different things per API (400 is a wrong password for
`SYNO.API.Auth`, a bad parameter for File Station); the deck knows the codes
of the Auth, File Station and Virtual Machine Manager guides and the ones
every API shares. The undocumented APIs get only the shared ones. Branch on
the field, not on the message:

```jennifer
try {
    $c = synology.login($c, "admin", $password);
} catch (e) {
    if ($e.kind == "synology" and $e.code == 403) {
        $c = synology.loginOtp($c, "admin", $password, askForCode(), "");
    } else {
        throw $e;
    }
}
```

A download over its `maxBytes`, or a reply over its size cap, is kind `"limit"`
(a plain `Error`).

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary, and the `net`
capability. DSM 6.2 or newer; DSM 7 is the main target, and Container
Manager needs DSM 7.2.
