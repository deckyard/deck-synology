<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Snapshots and jobs

Like [Administration](admin.md), these use undocumented APIs and an
administrator account.

## Snapshots

A shared folder on a Btrfs volume can be snapshotted:

```jennifer
def snap as string init synology.createSnapshot($c, "backup", "before the upgrade", true);
for (def s in synology.snapshots($c, "backup")) {
    io.printf("%s %s\n", $s.name, $s.description);
}
synology.deleteSnapshot($c, "backup", $snap);
```

A locked snapshot is kept when a retention policy removes old ones.

## Task Scheduler

```jennifer
for (def t in synology.scheduledTasks($c)) {
    if ($t.name == "Sync folders") {
        synology.runScheduledTask($c, $t);
        def last as list of synology.TaskResult init synology.taskResults($c, $t);
    }
}
```

The verbs take the `ScheduledTask` from `scheduledTasks`: DSM wants its id
with the account it runs as.

## Hyper Backup

```jennifer
for (def b in synology.backupTasks($c)) {
    def s as synology.BackupTask init synology.backupStatus($c, $b.id);
    io.printf("%s: last %s at %s, next %s\n", $s.name, $s.lastResult, $s.lastTime, $s.nextTime);
}
synology.runBackup($c, 3);
```

`runBackup` starts the task and returns; `backupStatus` shows its progress.
A task that is already running refuses to start again.
