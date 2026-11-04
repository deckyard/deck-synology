<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Containers

Container Manager (DSM 7.2 and newer) through `SYNO.Docker.*`, which
Synology does not document; the deck sends what the DSM web interface and
established clients send. The account needs to be an administrator.

## Deploying a Compose project

```jennifer
synology.mkdir($c, "/docker/web", true);
def id as string init synology.createProject($c, "web", "/docker/web", fs.readString("compose.yaml"));
synology.buildProject($c, $id);
io.printf("%s\n", synology.project($c, $id).status);
```

`createProject` writes `compose.yaml` into the folder, which has to exist.
`buildProject` pulls the images, builds what the file builds, and starts the
containers. To roll out a changed `compose.yaml`, stop and delete the
project with `keepFiles` true, which keeps the folder and the data in it,
then create and build it again.

```jennifer
for (def p in synology.projects($c)) {
    io.printf("%s %s %d containers\n", $p.name, $p.status, len($p.containerIds));
}
synology.stopProject($c, $id);
synology.deleteProject($c, $id, false);
```

## Containers

```jennifer
for (def k in synology.containers($c)) {
    io.printf("%s %s %s\n", $k.name, $k.image, $k.status);
}
synology.restartContainer($c, "web-caddy-1");
for (def line in synology.containerLogs($c, "web-caddy-1", 50)) {
    io.printf("%s %s\n", $line.stream, $line.text);
}
```

`inspectContainer` returns Docker's inspect data as it is (`Config`,
`HostConfig`, `State`, ...). `deleteContainer` with `force` removes a
running one.

## Images

```jennifer
synology.pullContainerImage($c, "caddy", "alpine");
for (def i in synology.containerImages($c)) {
    if ($i.upgradable) {
        io.printf("%s has a newer image\n", $i.repository);
    }
}
synology.deleteContainerImage($c, "caddy", "2.7");
```

Images come from the registry set in Container Manager, Docker Hub by
default. An image a container uses cannot be deleted.
