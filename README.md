# @deckyard/synology

[![test](https://github.com/deckyard/deck-synology/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-synology/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-synology/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-synology)](https://github.com/deckyard/deck-synology/releases/latest)

A client for the Synology DSM Web API, for
[Jennifer](https://jennifer-lang.dev/) programs: log in (with 2-step
verification and trusted devices), read the system summary, work with
File Station (shared folders, listing, creating, renaming, copying, moving,
deleting, upload and download), deploy and run virtual machines in Virtual
Machine Manager, manage local users, groups, shared folders and their
permissions, and administer the NAS: certificates, snapshots, health,
updates, power, packages, services, scheduled tasks and Hyper Backup.
Container Manager deploys Compose projects and runs containers. `call` reaches any other API under `/webapi`,
and DSM's numeric error codes come back as readable messages.

**[Documentation](https://deckyard.github.io/deck-synology/)**

## Install

```sh
jvc add @deckyard/synology
```

This vendors the deck to `vendor/<scope>/synology/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-synology-<version>.tar.gz`) there.

## Usage

```jennifer
import "@deckyard/synology/" as synology;

def c as synology.Client init synology.client("nas.example.com");
$c = synology.withCaCert($c, fs.readBytes("nas.pem"));
$c = synology.login($c, "backup", "secret");

synology.mkdir($c, "/backup/2024", true);
synology.upload($c, "/backup/2024", "db.sql.gz", fs.readBytes("db.sql.gz"), true);
for (def f in synology.files($c, "/backup/2024")) {
    io.printf("%s %d\n", $f.name, $f.size);
}
$c = synology.logout($c);
```

## Requirements

Jennifer 0.25.0 or newer, the default `jennifer` binary (not
`jennifer-tiny`), and the `net` capability. DSM 6.2 or newer; DSM 7 is the
main target, and Container Manager needs DSM 7.2.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/synology_test.j    # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
