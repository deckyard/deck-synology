<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# synology cheatsheet

Every export of `@deckyard/synology`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/synology/" as synology;
```

Every function that sends a request throws `Error{kind: "synology"}` when it
fails. A `path` or `folder` is a File Station path such as `/photo/2024`.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"synology"` | the `kind` of every error the deck throws |
| `DEFAULT_PORT` | `5001` | the port `client` adds to a bare host |
| `PAGE_SIZE` | `1000` | entries `files` and `shares` ask for per request |

## Types

### `Client`

| Field | Meaning |
|---|---|
| `url as string` | `https://host:5001`, without `/webapi` |
| `sessionName as string` | the DSM session `login` opens; `FileStation` |
| `sid as string` | the session id; `""` before `login` |
| `synoToken as string` | CSRF token sent as `X-SYNO-TOKEN` |
| `deviceId as string` | trusted-device id from `loginOtp` |
| `deviceName as string` | the device name that id was given for |
| `apis as map of string to ApiInfo` | the APIs `discover` found |
| `tls as http.TlsOptions` | certificate checking |
| `timeoutMs as int` | idle timeout per request; 0 for 30 s |
| `retries as int` | retries of a read answered 429 or 5xx |
| `pollMs as int` | interval of a background task's status checks; 0 for 1 s |
| `waitTimeoutMs as int` | how long to wait for a background task; 0 for 1 hour |

### `ApiInfo`

| Field | Meaning |
|---|---|
| `name as string` | e.g. `SYNO.FileStation.List` |
| `path as string` | the CGI under `/webapi`, e.g. `entry.cgi` |
| `minVersion as int` | the oldest version the host accepts |
| `maxVersion as int` | the newest version the host accepts |
| `requestFormat as string` | `JSON` when every parameter goes JSON-encoded |

### `SystemInfo`

| Field | Meaning |
|---|---|
| `model as string` | e.g. `DS920+` |
| `serial as string` | the serial number |
| `version as string` | e.g. `DSM 7.2.1-69057 Update 5` |
| `build as string` | the build number |
| `ramMb as int` | memory in MiB |
| `uptime as int` | seconds since boot |
| `temperature as int` | degrees Celsius |
| `overheated as bool` | whether DSM warns about the temperature |

### `Share`

| Field | Meaning |
|---|---|
| `name as string` | e.g. `photo` |
| `path as string` | `/photo` |
| `realPath as string` | `/volume1/photo` |
| `free as int` | free bytes on its volume |
| `total as int` | size of its volume in bytes |
| `readOnly as bool` | whether the volume is read-only |

### `File`

| Field | Meaning |
|---|---|
| `name as string` | the last path segment |
| `path as string` | the File Station path |
| `isDir as bool` | whether it is a folder |
| `size as int` | bytes; 0 for a folder |
| `modified as int` | last modification, Unix seconds |

### `VDisk`

| Field | Meaning |
|---|---|
| `id as string` | the vDisk id |
| `sizeMb as int` | its size in MiB |
| `controller as int` | 1 VirtIO, 2 IDE, 3 SATA |
| `unmap as bool` | whether space reclamation is on |

### `VNic`

| Field | Meaning |
|---|---|
| `id as string` | the vNIC id |
| `mac as string` | its MAC address |
| `model as int` | 1 VirtIO, 2 e1000, 3 rtl8139 |
| `networkId as string` | the network it is connected to; `""` for none |
| `networkName as string` | that network's name |

### `Guest`

| Field | Meaning |
|---|---|
| `id as string` | the guest id |
| `name as string` | the name the VM verbs take |
| `description as string` | the description |
| `status as string` | e.g. `running`, `shutdown`, `booting`, `creating` |
| `autorun as int` | after a host boot: 0 off, 1 the last state, 2 on |
| `storageId as string` | the storage it is on |
| `storageName as string` | that storage's name |
| `vcpus as int` | virtual CPUs |
| `ramMb as int` | memory in MiB |
| `disks as list of VDisk` | its virtual disks |
| `nics as list of VNic` | its virtual network cards |

### `DiskSpec`

| Field | Meaning |
|---|---|
| `sizeMb as int` | the size of an empty disk in MiB; ignored with an image |
| `image as string` | a disk image to copy; `""` for an empty disk |

### `GuestSpec`

| Field | Meaning |
|---|---|
| `name as string` | the new VM's name |
| `storage as string` | the storage it goes on |
| `disks as list of DiskSpec` | its disks; the first one boots |
| `networks as list of string` | a network name per vNIC; `""` for unconnected |
| `vcpus as int` | virtual CPUs; 0 for VMM's default |
| `ramMb as int` | memory in MiB; 0 for VMM's default |

### `VmHost`

| Field | Meaning |
|---|---|
| `id as string` | the host id |
| `name as string` | the host name |
| `status as string` | `running`, `inaccessible`, `network_warn` or `control_unavail` |
| `freeCpus as int` | free CPU threads |
| `totalCpus as int` | all CPU threads |
| `freeRamMb as int` | free memory in MiB |
| `totalRamMb as int` | all memory in MiB |

### `VmStorage`

| Field | Meaning |
|---|---|
| `id as string` | the storage id |
| `name as string` | e.g. `Synology - VM Storage 1` |
| `hostId as string` | the host it is on |
| `hostName as string` | that host's name |
| `status as string` | e.g. `online`, `degraded`, `full` |
| `sizeMb as int` | its size in MiB |
| `usedMb as int` | used MiB |
| `volumePath as string` | e.g. `/volume1` |

### `VmNetwork`

| Field | Meaning |
|---|---|
| `id as string` | the network id |
| `name as string` | e.g. `Default VM Network` |

### `VmImage`

| Field | Meaning |
|---|---|
| `id as string` | the image id |
| `name as string` | the name |
| `type as string` | `disk`, `vdsm` or `iso` |
| `storages as list of string` | the storages holding it |

### `User`

| Field | Meaning |
|---|---|
| `name as string` | the account name |
| `uid as int` | the user id |
| `description as string` | the description |
| `email as string` | the e-mail address |
| `expired as string` | `normal`, or `now` for a disabled account |

### `Group`

| Field | Meaning |
|---|---|
| `name as string` | the group name |
| `gid as int` | the group id |
| `description as string` | the description |

### `SharePermission`

| Field | Meaning |
|---|---|
| `name as string` | the user or group |
| `access as string` | `rw`, `ro`, `deny` or `none` |
| `isAdmin as bool` | whether it is an administrator |

### `Certificate`

| Field | Meaning |
|---|---|
| `id as string` | the certificate id |
| `description as string` | the description |
| `isDefault as bool` | whether it is the default |
| `commonName as string` | the subject, e.g. `nas.example.com` |
| `issuer as string` | the issuer's common name |
| `validFrom as string` | as DSM shows it |
| `validTill as string` | as DSM shows it |
| `services as list of string` | the services using it |

### `Snapshot`

| Field | Meaning |
|---|---|
| `name as string` | e.g. `GMT+01-2026.11.04-12.00.00` |
| `description as string` | the description |
| `locked as bool` | kept from automatic removal |
| `scheduled as bool` | whether a schedule took it |

### `Utilization`

| Field | Meaning |
|---|---|
| `cpuPercent as int` | CPU load, all kinds |
| `memoryPercent as int` | memory in use |
| `memoryTotalKb as int` | installed memory in KiB |
| `memoryAvailableKb as int` | available memory in KiB |
| `rxBytes as int` | bytes per second received |
| `txBytes as int` | bytes per second sent |

### `Volume`

| Field | Meaning |
|---|---|
| `id as string` | e.g. `volume_1` |
| `path as string` | e.g. `/volume1` |
| `status as string` | e.g. `normal`, `degraded`, `crashed` |
| `fsType as string` | e.g. `btrfs` |
| `totalBytes as int` | its size |
| `usedBytes as int` | bytes in use |

### `Disk`

| Field | Meaning |
|---|---|
| `id as string` | e.g. `sata1` |
| `name as string` | e.g. `Drive 1` |
| `model as string` | the model |
| `status as string` | e.g. `normal`, `warning`, `crashed` |
| `smartStatus as string` | e.g. `normal`, `failing` |
| `temperature as int` | degrees Celsius |
| `sizeBytes as int` | its size |

### `DsmUpdate`

| Field | Meaning |
|---|---|
| `available as bool` | whether an update is available |
| `version as string` | the version on offer; `""` without one |
| `reboot as string` | whether installing reboots, e.g. `now`, `none` |

### `Package`

| Field | Meaning |
|---|---|
| `id as string` | e.g. `ContainerManager` |
| `name as string` | e.g. `Container Manager` |
| `version as string` | the version |
| `status as string` | e.g. `running`, `stop` |

### `ScheduledTask`

| Field | Meaning |
|---|---|
| `id as int` | the task id |
| `name as string` | the name |
| `owner as string` | the account it runs as |
| `type as string` | e.g. `script`, `service` |
| `enabled as bool` | whether its schedule is on |
| `nextRun as string` | e.g. `2026-11-05 03:00` |
| `action as string` | what it does |

### `TaskResult`

| Field | Meaning |
|---|---|
| `start as string` | when it started |
| `stop as string` | when it ended |
| `exitCode as int` | the exit code |
| `exitType as string` | `normal` or `by_signal` |

### `BackupTask`

| Field | Meaning |
|---|---|
| `id as int` | the task id |
| `name as string` | the name |
| `state as string` | e.g. `backupable`, `backuping` |
| `status as string` | e.g. `none`, `waiting` |
| `lastResult as string` | e.g. `done`, `failed` |
| `lastTime as string` | when it last ran |
| `nextTime as string` | when it runs next |

### `Container`

| Field | Meaning |
|---|---|
| `name as string` | the container name |
| `id as string` | the container id |
| `image as string` | e.g. `caddy:alpine` |
| `status as string` | e.g. `running`, `stopped` |

### `ContainerImage`

| Field | Meaning |
|---|---|
| `id as string` | `sha256:...` |
| `repository as string` | e.g. `caddy`, `ghcr.io/owner/app` |
| `tags as list of string` | e.g. `["alpine"]` |
| `size as int` | bytes |
| `created as int` | Unix seconds |
| `upgradable as bool` | whether the registry has a newer image |

### `Project`

| Field | Meaning |
|---|---|
| `id as string` | the project id |
| `name as string` | the project name |
| `path as string` | its folder, e.g. `/docker/app` |
| `status as string` | e.g. `RUNNING`, `STOPPED` |
| `containerIds as list of string` | its containers |

### `LogLine`

| Field | Meaning |
|---|---|
| `created as string` | RFC 3339 |
| `stream as string` | `stdout` or `stderr` |
| `text as string` | the line |

## Connecting

| Function | Returns | Does |
|---|---|---|
| `synology.client(address)` | `Client` | a client for a host, not logged in |
| `synology.withCaCert(c, pem)` | `Client` | trust a certificate |
| `synology.withInsecure(c)` | `Client` | accept any certificate |
| `synology.withTimeout(c, ms)` | `Client` | set the idle timeout |
| `synology.withRetries(c, n)` | `Client` | retry reads answered 429 or 5xx |
| `synology.withPollInterval(c, ms)` | `Client` | set the task check interval |
| `synology.withWaitTimeout(c, ms)` | `Client` | set how long to wait for a task |
| `synology.withSessionName(c, name)` | `Client` | name the session `login` opens |
| `synology.withSession(c, sid, synoToken)` | `Client` | reuse a stored session |
| `synology.withDeviceId(c, deviceId, deviceName)` | `Client` | present a trusted device |
| `synology.discover(c)` | `Client` | find the deck's APIs on the host |
| `synology.apiInfo(c, api)` | `ApiInfo` | where an API lives and its versions |
| `synology.login(c, account, password)` | `Client` | log in and keep the session |
| `synology.loginOtp(c, account, password, code, deviceName)` | `Client` | log in with a 2-step code; trust the device when named |
| `synology.logout(c)` | `Client` | end the session |
| `synology.refreshToken(c)` | `Client` | get a new CSRF token for the session |
| `synology.call(c, api, version, method, params)` | `json.Value` | any method of any API; version 0 for the newest |

## System

| Function | Returns | Does |
|---|---|---|
| `synology.info(c)` | `SystemInfo` | model, DSM version, memory, uptime, temperature |

## Files

| Function | Returns | Does |
|---|---|---|
| `synology.shares(c)` | `list of Share` | the shared folders the account can see |
| `synology.files(c, folder)` | `list of File` | a folder's entries, folders first |
| `synology.stat(c, path)` | `File` | one entry |
| `synology.exists(c, path)` | `bool` | whether a path exists |
| `synology.mkdir(c, path, parents)` | `File` | create a folder, and missing parents when `parents` |
| `synology.rename(c, path, name)` | `File` | rename in place |
| `synology.copy(c, path, folder, overwrite)` | `string` | copy into a folder; the new path |
| `synology.move(c, path, folder, overwrite)` | `string` | move into a folder; the new path |
| `synology.delete(c, path)` | | delete a file, or a folder and its contents |
| `synology.upload(c, folder, name, data, overwrite)` | `string` | upload bytes; the file's path |
| `synology.download(c, path, maxBytes)` | `bytes` | download a file; a folder as a zip |


## Virtual Machine Manager

| Function | Returns | Does |
|---|---|---|
| `synology.guests(c)` | `list of Guest` | the virtual machines |
| `synology.guest(c, name)` | `Guest` | one virtual machine |
| `synology.createGuest(c, spec)` | `Guest` | create one and wait; it stays off |
| `synology.resizeGuest(c, name, vcpus, ramMb)` | | change CPUs and memory; 0 keeps |
| `synology.renameGuest(c, name, newName)` | | rename one |
| `synology.setAutorun(c, name, mode)` | | `off`, `last` or `on` after a host boot |
| `synology.deleteGuest(c, name)` | | delete one and its disks |
| `synology.powerOnGuest(c, name)` | | power on |
| `synology.shutdownGuest(c, name)` | | shut down through the guest OS |
| `synology.powerOffGuest(c, name)` | | cut the power |
| `synology.vmHosts(c)` | `list of VmHost` | the hosts, with free CPU and memory |
| `synology.vmStorages(c)` | `list of VmStorage` | the storages |
| `synology.vmNetworks(c)` | `list of VmNetwork` | the networks |
| `synology.vmImages(c)` | `list of VmImage` | the images |
| `synology.createImage(c, name, type, file, storages)` | `string` | import a file on the NAS as an image; its id |
| `synology.deleteImage(c, name)` | | delete an image |

## Users, groups and shares

| Function | Returns | Does |
|---|---|---|
| `synology.users(c)` | `list of User` | the local accounts |
| `synology.user(c, name)` | `User` | one account |
| `synology.createUser(c, name, password, description, email)` | `User` | create an account |
| `synology.setUserPassword(c, name, password)` | | set its password |
| `synology.setUserEnabled(c, name, enabled)` | | enable or disable it |
| `synology.deleteUser(c, name)` | | delete it |
| `synology.groups(c)` | `list of Group` | the local groups |
| `synology.groupMembers(c, group)` | `list of string` | a group's accounts |
| `synology.addToGroup(c, group, names)` | | add accounts |
| `synology.removeFromGroup(c, group, names)` | | remove accounts |
| `synology.createShare(c, name, volume, description)` | `string` | create a shared folder; its path |
| `synology.deleteShare(c, name)` | | delete a shared folder and its contents |
| `synology.sharePermissions(c, share, kind)` | `list of SharePermission` | each `user` or `group` and its access |
| `synology.setSharePermission(c, share, kind, name, access)` | | set one user's or group's access |

## Certificates

| Function | Returns | Does |
|---|---|---|
| `synology.certificates(c)` | `list of Certificate` | the certificates and their services |
| `synology.importCertificate(c, key, cert, chain, description, replaceId, asDefault)` | `string` | import or renew one; its id |
| `synology.setDefaultCertificate(c, id)` | | make it the default |
| `synology.deleteCertificate(c, id)` | | delete one |
| `synology.assignCertificate(c, id, service)` | | let a service use it |

## Snapshots

| Function | Returns | Does |
|---|---|---|
| `synology.snapshots(c, share)` | `list of Snapshot` | a share's snapshots |
| `synology.createSnapshot(c, share, description, lock)` | `string` | take one; its name |
| `synology.deleteSnapshot(c, share, name)` | | delete one |

## Health and system

| Function | Returns | Does |
|---|---|---|
| `synology.utilization(c)` | `Utilization` | CPU, memory and network load |
| `synology.volumes(c)` | `list of Volume` | the volumes and their state |
| `synology.disks(c)` | `list of Disk` | the drives, health and temperature |
| `synology.checkUpdate(c)` | `DsmUpdate` | whether a DSM update is available |
| `synology.reboot(c)` | | restart the NAS |
| `synology.shutdown(c)` | | turn the NAS off |

## Packages and services

| Function | Returns | Does |
|---|---|---|
| `synology.packages(c)` | `list of Package` | the installed packages |
| `synology.startPackage(c, id)` | | start one |
| `synology.stopPackage(c, id)` | | stop one |
| `synology.serviceEnabled(c, service)` | `bool` | whether `ssh`, `smb` or `nfs` is on |
| `synology.setService(c, service, enabled)` | | turn it on or off |

## Scheduled tasks and Hyper Backup

| Function | Returns | Does |
|---|---|---|
| `synology.scheduledTasks(c)` | `list of ScheduledTask` | the Task Scheduler's tasks |
| `synology.runScheduledTask(c, job)` | | run one now |
| `synology.setScheduledTaskEnabled(c, job, enabled)` | | turn its schedule on or off |
| `synology.taskResults(c, job)` | `list of TaskResult` | its recent runs |
| `synology.backupTasks(c)` | `list of BackupTask` | the Hyper Backup tasks |
| `synology.backupStatus(c, id)` | `BackupTask` | one task and its last run |
| `synology.runBackup(c, id)` | | start a backup now |

## Container Manager

| Function | Returns | Does |
|---|---|---|
| `synology.containers(c)` | `list of Container` | the containers, running or not |
| `synology.inspectContainer(c, name)` | `json.Value` | Docker's inspect data |
| `synology.startContainer(c, name)` | | start one |
| `synology.stopContainer(c, name)` | | stop one |
| `synology.restartContainer(c, name)` | | restart one |
| `synology.deleteContainer(c, name, force)` | | delete one; `force` while it runs |
| `synology.containerLogs(c, name, limit)` | `list of LogLine` | its newest lines, newest first |
| `synology.containerImages(c)` | `list of ContainerImage` | the images on the NAS |
| `synology.pullContainerImage(c, repository, tag)` | | pull an image |
| `synology.deleteContainerImage(c, repository, tag)` | | delete an image |
| `synology.projects(c)` | `list of Project` | the Compose projects |
| `synology.project(c, id)` | `Project` | one project |
| `synology.createProject(c, name, folder, compose)` | `string` | create one from a `compose.yaml`; its id |
| `synology.buildProject(c, id)` | | pull, build and start it |
| `synology.startProject(c, id)` | | start its containers |
| `synology.stopProject(c, id)` | | stop its containers |
| `synology.deleteProject(c, id, keepFiles)` | | delete it and its containers |
