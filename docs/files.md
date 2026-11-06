<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Files

Everything here goes through File Station, so the account needs the File
Station application privilege and access to the shared folder.

## Shares and folders

```jennifer
for (def s in synology.shares($c)) {
    io.printf("%s on %s: %d bytes free\n", $s.name, $s.realPath, $s.free);
}
for (def f in synology.files($c, "/photo/2024")) {
    io.printf("%s %d\n", $f.path, $f.size);
}
```

`files` lists one folder, folders first, by name, and fetches every page.
`stat` describes one path; `exists` says whether it is there:

```jennifer
if (not synology.exists($c, "/backup/2024")) {
    synology.mkdir($c, "/backup/2024", true);
}
```

`mkdir` with `parents` true creates missing parent folders and accepts a
folder that is already there. Shared folders themselves are created and
deleted in DSM's Control Panel, not through File Station; the deck refuses a
path of one segment for `mkdir` and `delete`.

## Changing files

```jennifer
synology.rename($c, "/backup/db.sql.gz", "db-2024-06-01.sql.gz");
synology.copy($c, "/backup/db-2024-06-01.sql.gz", "/archive", false);
synology.move($c, "/inbox/scan.pdf", "/documents", false);
synology.delete($c, "/backup/2023");
```

`copy`, `move` and `delete` start a background task on the NAS and wait until
it is done, checking every second (`withPollInterval`) for at most an hour
(`withWaitTimeout`); when the time runs out the call fails and the task goes
on in DSM. With `overwrite` false, an entry of the same name in the destination is an error, never a
silent skip. `delete` removes a folder with everything in it.

## Upload and download

```jennifer
synology.upload($c, "/backup/db", "db.sql.gz", fs.readBytes("db.sql.gz"), true);
def data as bytes init synology.download($c, "/backup/db/db.sql.gz", 0);
fs.writeBytes("restored.sql.gz", $data);
```

`upload` creates missing folders. Both hold the whole file in memory.
`download` refuses a reply larger than its limit, 64 MiB with 0; pass a
larger one for big files. A folder downloads as a zip archive.
