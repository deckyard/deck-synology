<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Users, groups and shares

These verbs use `SYNO.Core.User`, `SYNO.Core.Group`, `SYNO.Core.Share` and
their companions. Synology does not document them; the deck sends what the
DSM web interface and established clients send. The account needs to be an
administrator.

## Accounts

```jennifer
synology.createUser($c, "ci", fs.readString("/run/secrets/ci"), "CI runner", "");
synology.addToGroup($c, "administrators", ["ci"]);
for (def u in synology.users($c)) {
    io.printf("%s %s\n", $u.name, $u.expired);
}
synology.setUserEnabled($c, "ci", false);
```

A disabled account has `expired` `now`. `setUserPassword` replaces a
password; DSM's password policy decides what it accepts. Names hold no
comma or backslash.

## Shared folders

```jennifer
def path as string init synology.createShare($c, "backup", "/volume1", "nightly dumps");
synology.setSharePermission($c, "backup", "user", "ci", "rw");
synology.setSharePermission($c, "backup", "group", "users", "none");
for (def p in synology.sharePermissions($c, "backup", "user")) {
    io.printf("%s %s\n", $p.name, $p.access);
}
```

`createShare` makes a share with its recycle bin on, for administrators
only; anything else (encryption, quotas, snapshots) is a `call` away.
`shares` lists them, as File Station sees them. An access is `rw`, `ro`,
`deny` or `none`; `deny` wins over what a group grants. `deleteShare`
removes the folder and everything in it.
