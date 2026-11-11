# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Upload a file into a dated folder on a Synology NAS and list the folder.
 *
 *   NAS=nas.example.com NAS_USER=backup NAS_PASSWORD=... \
 *       jennifer run examples/backup.j db.sql.gz
 *
 * Trusts any certificate, as a NAS out of the box has a self-signed one;
 * use synology.withCaCert for anything that matters.
 */
use fs;
use io;
use os;
use path;
use time;

import "../src/synology.j" as synology;

if (len(os.ARGS) != 2) {
    throw Error{kind: "usage", message: "usage: backup.j <file>"};
}
def local as string init os.ARGS[1];

def c as synology.Client init synology.withInsecure(synology.client(os.getEnv("NAS")));
$c = synology.login($c, os.getEnv("NAS_USER"), os.getEnv("NAS_PASSWORD"));
def nas as synology.SystemInfo init synology.info($c);
io.printf("%s, %s\n", $nas.model, $nas.version);

def folder as string init "/backup/" + time.format(time.now(), "%Y-%m-%d");
synology.mkdir($c, $folder, true);
def stored as string init synology.upload(
    $c,
    $folder,
    path.base($local),
    fs.readBytes($local),
    true);
io.printf("stored %s\n", $stored);

for (def f in synology.files($c, $folder)) {
    io.printf("  %s %d bytes\n", $f.name, $f.size);
}
$c = synology.logout($c);
