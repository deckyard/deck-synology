# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * A client for the Synology DSM Web API.
 *
 * DSM publishes its APIs under `/webapi`: `SYNO.API.Info` says where each one
 * lives and which versions it speaks, `SYNO.API.Auth` logs in and hands out a
 * session id (`sid`), and every reply is `{"success": ..., "data": ...}`.
 * `call` reaches any API; typed verbs cover the system summary, File
 * Station (shares, folders, files, upload and download) and Virtual Machine
 * Manager (virtual machines, images, power).
 *
 * A NAS usually presents a self-signed certificate: trust it with
 * `withCaCert`, or turn checking off with `withInsecure`. Every failure is a
 * `SynologyError` (kind `"synology"`); DSM's numeric error codes are
 * translated in the message and kept in its `code` field. A download over
 * `maxBytes`, or a reply over its size cap, is kind `"limit"`.
 *
 * @module synology
 * @see https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf
 * @example
 *   def c as synology.Client init synology.client("nas.example.com");
 *   $c = synology.login($c, "backup", "secret");
 *   for (def f in synology.files($c, "/backup")) {
 *       io.printf("%s %d\n", $f.name, $f.size);
 *   }
 *   $c = synology.logout($c);
 */
use convert;
use json;
use lists;
use maps;
use regex;
use strings;
use time;
import "http.j" as http;
import "multipart.j" as multipart;
import "uri.j" as uri;

/** The `kind` of every error the deck throws. */
export def const ERROR_KIND as string init "synology";

/** The port a bare host name gets: DSM's HTTPS port. */
export def const DEFAULT_PORT as int init 5001;

/** The most entries `files` and `shares` ask for per request. */
export def const PAGE_SIZE as int init 1000;

/**
 * A connection to one DSM host. Build it with `client` and the `with*`
 * functions; `login` fills in the session.
 *
 * @field url {string} `https://host:port`, without `/webapi`
 * @field sessionName {string} the DSM session the login opens
 * @field sid {string} the session id; "" before `login`
 * @field synoToken {string} the CSRF token sent as `X-SYNO-TOKEN`
 * @field deviceId {string} the trusted-device id that skips the 2-step code
 * @field deviceName {string} the device name the id was given for
 * @field apis {map of string to ApiInfo} the APIs found by `discover`
 * @field tls {http.TlsOptions} certificate checking
 * @field timeoutMs {int} the idle timeout of each request; 0 for 30 s
 * @field retries {int} retries of a read answered 429 or 5xx
 * @field pollMs {int} the delay between checks of a background task; 0 for
 *   1 s
 * @field waitTimeoutMs {int} how long to wait for a background task; 0 for
 *   1 hour
 */
export def struct Client {
    url as string,
    sessionName as string,
    sid as string,
    synoToken as string,
    deviceId as string,
    deviceName as string,
    apis as map of string to ApiInfo,
    tls as http.TlsOptions,
    timeoutMs as int,
    retries as int,
    pollMs as int,
    waitTimeoutMs as int
};

/**
 * Where an API lives and which versions the host speaks.
 *
 * @field name {string} e.g. `SYNO.FileStation.List`
 * @field path {string} the CGI under `/webapi`, e.g. `entry.cgi`
 * @field minVersion {int} the oldest version the host accepts
 * @field maxVersion {int} the newest version the host accepts
 * @field requestFormat {string} `JSON` when every parameter value goes
 *   JSON-encoded; "" otherwise
 */
export def struct ApiInfo {
    name as string,
    path as string,
    minVersion as int,
    maxVersion as int,
    requestFormat as string
};

/**
 * The host's summary from `SYNO.DSM.Info`.
 *
 * @field model {string} e.g. `DS920+`
 * @field serial {string} the serial number
 * @field version {string} e.g. `DSM 7.2.1-69057 Update 5`
 * @field build {string} the build number, e.g. `69057`
 * @field ramMb {int} installed memory in MiB
 * @field uptime {int} seconds since boot
 * @field temperature {int} the system temperature in degrees Celsius
 * @field overheated {bool} whether DSM warns about the temperature
 */
export def struct SystemInfo {
    model as string,
    serial as string,
    version as string,
    build as string,
    ramMb as int,
    uptime as int,
    temperature as int,
    overheated as bool
};

/**
 * A shared folder.
 *
 * @field name {string} e.g. `photo`
 * @field path {string} the File Station path, e.g. `/photo`
 * @field realPath {string} the path on the volume, e.g. `/volume1/photo`
 * @field free {int} free bytes on its volume
 * @field total {int} size of its volume in bytes
 * @field readOnly {bool} whether the volume is read-only
 */
export def struct Share {
    name as string,
    path as string,
    realPath as string,
    free as int,
    total as int,
    readOnly as bool
};

/**
 * A file or folder.
 *
 * @field name {string} the last path segment
 * @field path {string} the File Station path, e.g. `/photo/2024/a.jpg`
 * @field isDir {bool} whether it is a folder
 * @field size {int} bytes; 0 for a folder
 * @field modified {int} last modification, Unix seconds
 */
export def struct File {
    name as string,
    path as string,
    isDir as bool,
    size as int,
    modified as int
};

/**
 * A virtual disk of a virtual machine.
 *
 * @field id {string} the vDisk id
 * @field sizeMb {int} its size in MiB
 * @field controller {int} 1 VirtIO, 2 IDE, 3 SATA
 * @field unmap {bool} whether space reclamation is on
 */
export def struct VDisk {
    id as string,
    sizeMb as int,
    controller as int,
    unmap as bool
};

/**
 * A virtual network card of a virtual machine.
 *
 * @field id {string} the vNIC id
 * @field mac {string} its MAC address
 * @field model {int} 1 VirtIO, 2 e1000, 3 rtl8139
 * @field networkId {string} the network it is connected to; "" for none
 * @field networkName {string} that network's name
 */
export def struct VNic {
    id as string,
    mac as string,
    model as int,
    networkId as string,
    networkName as string
};

/**
 * A virtual machine of Virtual Machine Manager.
 *
 * @field id {string} the guest id
 * @field name {string} the name, which the deck's verbs take
 * @field description {string} the description
 * @field status {string} e.g. `running`, `shutdown`, `booting`, `creating`
 * @field autorun {int} after a host boot: 0 off, 1 the last state, 2 on
 * @field storageId {string} the storage it resides on
 * @field storageName {string} that storage's name
 * @field vcpus {int} virtual CPUs
 * @field ramMb {int} memory in MiB
 * @field disks {list of VDisk} its virtual disks
 * @field nics {list of VNic} its virtual network cards
 */
export def struct Guest {
    id as string,
    name as string,
    description as string,
    status as string,
    autorun as int,
    storageId as string,
    storageName as string,
    vcpus as int,
    ramMb as int,
    disks as list of VDisk,
    nics as list of VNic
};

/**
 * A disk for `createGuest`: empty, or a copy of a disk image.
 *
 * @field sizeMb {int} the size in MiB of an empty disk; ignored with an image
 * @field image {string} the name of a disk image to copy; "" for an empty disk
 */
export def struct DiskSpec {
    sizeMb as int,
    image as string
};

/**
 * What `createGuest` makes.
 *
 * @field name {string} the new virtual machine's name
 * @field storage {string} the name of the storage it goes on (`vmStorages`)
 * @field disks {list of DiskSpec} its disks, the first one boots
 * @field networks {list of string} a network name per vNIC (`vmNetworks`);
 *   "" for a vNIC that is not connected
 * @field vcpus {int} virtual CPUs; 0 for VMM's default
 * @field ramMb {int} memory in MiB; 0 for VMM's default
 */
export def struct GuestSpec {
    name as string,
    storage as string,
    disks as list of DiskSpec,
    networks as list of string,
    vcpus as int,
    ramMb as int
};

/**
 * A host of Virtual Machine Manager: the NAS, or a member of its cluster.
 *
 * @field id {string} the host id
 * @field name {string} the host name
 * @field status {string} `running`, `inaccessible`, `network_warn` or
 *   `control_unavail`
 * @field freeCpus {int} free CPU threads
 * @field totalCpus {int} all CPU threads
 * @field freeRamMb {int} free memory in MiB
 * @field totalRamMb {int} all memory in MiB
 */
export def struct VmHost {
    id as string,
    name as string,
    status as string,
    freeCpus as int,
    totalCpus as int,
    freeRamMb as int,
    totalRamMb as int
};

/**
 * A storage of Virtual Machine Manager, on a volume of a host.
 *
 * @field id {string} the storage id
 * @field name {string} the name, e.g. `Synology - VM Storage 1`
 * @field hostId {string} the host it is on
 * @field hostName {string} that host's name
 * @field status {string} e.g. `online`, `degraded`, `full`
 * @field sizeMb {int} its size in MiB; 0 while the host is missing
 * @field usedMb {int} used MiB; 0 while the host is missing
 * @field volumePath {string} e.g. `/volume1`
 */
export def struct VmStorage {
    id as string,
    name as string,
    hostId as string,
    hostName as string,
    status as string,
    sizeMb as int,
    usedMb as int,
    volumePath as string
};

/**
 * A network of Virtual Machine Manager.
 *
 * @field id {string} the network id
 * @field name {string} the name, e.g. `Default VM Network`
 */
export def struct VmNetwork {
    id as string,
    name as string
};

/**
 * An image of Virtual Machine Manager: a disk to copy, a Virtual DSM image
 * or an ISO.
 *
 * @field id {string} the image id
 * @field name {string} the name
 * @field type {string} `disk`, `vdsm` or `iso`
 * @field storages {list of string} the names of the storages holding it
 */
export def struct VmImage {
    id as string,
    name as string,
    type as string,
    storages as list of string
};

/**
 * A local DSM account.
 *
 * @field name {string} the account name
 * @field uid {int} the user id
 * @field description {string} the description
 * @field email {string} the e-mail address
 * @field expired {string} `normal`, or `now` for a disabled account
 */
export def struct User {
    name as string,
    uid as int,
    description as string,
    email as string,
    expired as string
};

/**
 * A local DSM group.
 *
 * @field name {string} the group name
 * @field gid {int} the group id
 * @field description {string} the description
 */
export def struct Group {
    name as string,
    gid as int,
    description as string
};

/**
 * What one user or group may do in a shared folder.
 *
 * @field name {string} the user or group
 * @field access {string} `rw`, `ro`, `deny` or `none`
 * @field isAdmin {bool} whether it is an administrator
 */
export def struct SharePermission {
    name as string,
    access as string,
    isAdmin as bool
};

/**
 * A certificate of DSM.
 *
 * @field id {string} the certificate id
 * @field description {string} the description
 * @field isDefault {bool} whether it is the default certificate
 * @field commonName {string} the subject's common name, e.g. `nas.example.com`
 * @field issuer {string} the issuer's common name
 * @field validFrom {string} as DSM shows it
 * @field validTill {string} as DSM shows it
 * @field services {list of string} the services using it, e.g.
 *   `DSM Desktop Service`
 */
export def struct Certificate {
    id as string,
    description as string,
    isDefault as bool,
    commonName as string,
    issuer as string,
    validFrom as string,
    validTill as string,
    services as list of string
};

/**
 * A snapshot of a shared folder.
 *
 * @field name {string} the snapshot, e.g. `GMT+01-2026.11.04-12.00.00`
 * @field description {string} the description
 * @field locked {bool} whether it is kept from automatic removal
 * @field scheduled {bool} whether a schedule took it
 */
export def struct Snapshot {
    name as string,
    description as string,
    locked as bool,
    scheduled as bool
};

/**
 * How busy the NAS is right now.
 *
 * @field cpuPercent {int} CPU load, user, system and other together
 * @field memoryPercent {int} memory in use
 * @field memoryTotalKb {int} installed memory in KiB
 * @field memoryAvailableKb {int} available memory in KiB
 * @field rxBytes {int} bytes per second received, all interfaces
 * @field txBytes {int} bytes per second sent, all interfaces
 */
export def struct Utilization {
    cpuPercent as int,
    memoryPercent as int,
    memoryTotalKb as int,
    memoryAvailableKb as int,
    rxBytes as int,
    txBytes as int
};

/**
 * A storage volume.
 *
 * @field id {string} e.g. `volume_1`
 * @field path {string} e.g. `/volume1`
 * @field status {string} e.g. `normal`, `degraded`, `crashed`
 * @field fsType {string} e.g. `btrfs`, `ext4`
 * @field totalBytes {int} its size
 * @field usedBytes {int} bytes in use
 */
export def struct Volume {
    id as string,
    path as string,
    status as string,
    fsType as string,
    totalBytes as int,
    usedBytes as int
};

/**
 * A drive.
 *
 * @field id {string} e.g. `sata1`
 * @field name {string} e.g. `Drive 1`
 * @field model {string} the model
 * @field status {string} e.g. `normal`, `warning`, `crashed`
 * @field smartStatus {string} e.g. `normal`, `warning`, `failing`
 * @field temperature {int} degrees Celsius
 * @field sizeBytes {int} its size
 */
export def struct Disk {
    id as string,
    name as string,
    model as string,
    status as string,
    smartStatus as string,
    temperature as int,
    sizeBytes as int
};

/**
 * What DSM's update server offers.
 *
 * @field available {bool} whether an update is available
 * @field version {string} e.g. `DSM 7.2.2-72806 Update 3`; "" without one
 * @field reboot {string} whether installing it reboots: `now`, `none`, ...
 */
export def struct DsmUpdate {
    available as bool,
    version as string,
    reboot as string
};

/**
 * An installed package.
 *
 * @field id {string} e.g. `ContainerManager`
 * @field name {string} e.g. `Container Manager`
 * @field version {string} e.g. `24.0.2-1535`
 * @field status {string} e.g. `running`, `stop`
 */
export def struct Package {
    id as string,
    name as string,
    version as string,
    status as string
};

/**
 * A task of the Task Scheduler.
 *
 * @field id {int} the task id
 * @field name {string} the name
 * @field owner {string} the account it runs as
 * @field type {string} e.g. `script`, `service`, `recycle`
 * @field enabled {bool} whether its schedule is on
 * @field nextRun {string} e.g. `2026-11-05 03:00`
 * @field action {string} what it does, as DSM describes it
 */
export def struct ScheduledTask {
    id as int,
    name as string,
    owner as string,
    type as string,
    enabled as bool,
    nextRun as string,
    action as string
};

/**
 * One run of a scheduled task.
 *
 * @field start {string} e.g. `2026-11-04 03:00:01`
 * @field stop {string} when it ended
 * @field exitCode {int} the exit code
 * @field exitType {string} `normal` or `by_signal`
 */
export def struct TaskResult {
    start as string,
    stop as string,
    exitCode as int,
    exitType as string
};

/**
 * A Hyper Backup task.
 *
 * @field id {int} the task id
 * @field name {string} the name
 * @field state {string} e.g. `backupable`, `backuping`
 * @field status {string} e.g. `none`, `waiting`, `backup`
 * @field lastResult {string} e.g. `done`, `failed`; "" before the first run
 * @field lastTime {string} when it last ran
 * @field nextTime {string} when it runs next
 */
export def struct BackupTask {
    id as int,
    name as string,
    state as string,
    status as string,
    lastResult as string,
    lastTime as string,
    nextTime as string
};

/**
 * A container of Container Manager.
 *
 * @field name {string} the container name
 * @field id {string} the container id
 * @field image {string} the image it runs, e.g. `caddy:alpine`
 * @field status {string} e.g. `running`, `stopped`
 */
export def struct Container {
    name as string,
    id as string,
    image as string,
    status as string
};

/**
 * A container image on the NAS.
 *
 * @field id {string} the image id, `sha256:...`
 * @field repository {string} e.g. `caddy`, `ghcr.io/owner/app`
 * @field tags {list of string} e.g. `["alpine"]`
 * @field size {int} bytes
 * @field created {int} Unix seconds
 * @field upgradable {bool} whether the registry has a newer image for a tag
 */
export def struct ContainerImage {
    id as string,
    repository as string,
    tags as list of string,
    size as int,
    created as int,
    upgradable as bool
};

/**
 * A Compose project of Container Manager.
 *
 * @field id {string} the project id
 * @field name {string} the project name
 * @field path {string} its folder, a File Station path such as `/docker/app`
 * @field status {string} e.g. `RUNNING`, `STOPPED`
 * @field containerIds {list of string} the ids of its containers
 */
export def struct Project {
    id as string,
    name as string,
    path as string,
    status as string,
    containerIds as list of string
};

/**
 * A line a container wrote.
 *
 * @field created {string} RFC 3339
 * @field stream {string} `stdout` or `stderr`
 * @field text {string} the line
 */
export def struct LogLine {
    created as string,
    stream as string,
    text as string
};

# The APIs `discover` keeps: the trailing dot asks for the whole family.
def const KNOWN_APIS as string init "SYNO.API.Auth,SYNO.DSM.Info,SYNO.FileStation.," +
    "SYNO.Virtualization.API.,SYNO.Core.User,SYNO.Core.Group,SYNO.Core.Group.Member," +
    "SYNO.Core.Share,SYNO.Core.Share.Permission,SYNO.Core.Share.Snapshot," +
    "SYNO.Core.Certificate,SYNO.Core.Certificate.CRT,SYNO.Core.Certificate.Service," +
    "SYNO.Core.System,SYNO.Core.System.Utilization,SYNO.Storage.CGI.Storage," +
    "SYNO.Core.Upgrade.Server,SYNO.Core.Package,SYNO.Core.Package.Control," +
    "SYNO.Core.Terminal,SYNO.Core.FileServ.SMB,SYNO.Core.FileServ.NFS," +
    "SYNO.Core.TaskScheduler,SYNO.Backup.Task,SYNO.Docker.Container," +
    "SYNO.Docker.Container.Log,SYNO.Docker.Image,SYNO.Docker.Project";

# What a CGI path from SYNO.API.Info may look like.
def const CGI_PATTERN as string init "^[A-Za-z0-9_][A-Za-z0-9_/.-]*$";

# Codes every API shares, from the DSM Login and File Station guides.
def const COMMON_ERRORS as map of string to string init {
    "100": "unknown error",
    "101": "no parameter of API, method or version",
    "102": "the requested API does not exist",
    "103": "the requested method does not exist",
    "104": "the requested version does not support the functionality",
    "105": "the logged in session does not have permission",
    "106": "session timeout",
    "107": "session interrupted by duplicate login",
    "108": "failed to upload the file",
    "109": "the network connection is unstable or the system is busy",
    "110": "the network connection is unstable or the system is busy",
    "111": "the network connection is unstable or the system is busy",
    "114": "lost parameters for this API",
    "115": "not allowed to upload a file",
    "116": "not allowed to perform for a demo site",
    "117": "the network connection is unstable or the system is busy",
    "118": "the network connection is unstable or the system is busy",
    "119": "invalid session",
    "150": "the request source IP does not match the login IP",
    "160": "insufficient application privilege"
};

# SYNO.API.Auth's own codes.
def const AUTH_ERRORS as map of string to string init {
    "400": "no such account or incorrect password",
    "401": "disabled account",
    "402": "denied permission",
    "403": "2-step verification code required",
    "404": "failed to authenticate 2-step verification code",
    "406": "2-step verification is enforced for this account",
    "407": "blocked IP source",
    "408": "expired password cannot change",
    "409": "expired password",
    "410": "password must be changed"
};

# SYNO.Virtualization.API.*'s own codes, from the Virtual Machine Manager guide.
def const VMM_ERRORS as map of string to string init {
    "401": "bad parameter",
    "402": "operation failed",
    "403": "name conflict",
    "404": "the number of iSCSI LUNs has reached the system limit",
    "500": "the cluster is frozen; more than half of the hosts are offline",
    "501": "the cluster is in incompatible mode",
    "600": "the cluster is not ready",
    "601": "the host is offline",
    "700": "the storage is invalid",
    "900": "failed to set a host to the virtual machine",
    "901": "the virtual machine does not have a host",
    "902": "not enough CPU threads to power on the virtual machine",
    "903": "not enough memory to power on the virtual machine",
    "904": "the virtual machine is online",
    "905": "MAC conflict",
    "906": "the selected image is not found",
    "907": "the virtual machine is offline",
    "908": "not enough CPU threads for the reservation on the host",
    "909": "the host has no corresponding network",
    "910": "only a VirtIO disk controller can boot the virtual machine remotely",
    "911": "a virtual machine with UEFI cannot be powered on remotely",
    "1000": "cannot find the task",
    "1001": "needs Virtual Machine Manager Pro",
    "1400": "the image was only partly created",
    "1600": "edited, but reserving memory or CPU on the HA hosts failed"
};

# SYNO.FileStation.*'s own codes.
def const FILE_ERRORS as map of string to string init {
    "400": "invalid parameter of file operation",
    "401": "unknown error of file operation",
    "402": "system is too busy",
    "403": "invalid user does this file operation",
    "404": "invalid group does this file operation",
    "405": "invalid user and group does this file operation",
    "406": "can't get user/group information from the account server",
    "407": "operation not permitted",
    "408": "no such file or directory",
    "409": "non-supported file system",
    "410": "failed to connect internet-based file system",
    "411": "read-only file system",
    "412": "filename too long in the non-encrypted file system",
    "413": "filename too long in the encrypted file system",
    "414": "file already exists",
    "415": "disk quota exceeded",
    "416": "no space left on device",
    "417": "input/output error",
    "418": "illegal name or path",
    "419": "illegal file name",
    "420": "illegal file name on FAT file system",
    "421": "device or resource busy",
    "599": "no such task of the file operation",
    "900": "failed to delete file(s)/folder(s)",
    "1000": "failed to copy files/folders",
    "1001": "failed to move files/folders",
    "1002": "an error occurred at the destination",
    "1100": "failed to create a folder",
    "1101": "the number of folders to the parent folder would exceed the system limitation",
    "1200": "failed to rename it",
    "1800": "there is no Content-Length information in the HTTP header",
    "1801": "wait too long, no data can be received from the client",
    "1802": "no filename information in the last part of file content",
    "1803": "upload connection is cancelled",
    "1804": "failed to upload oversized file to FAT file system",
    "1805": "can't overwrite or skip the existing file"
};

/**
 * A failed request or a refused value. Every error of kind `"synology"` is
 * one, so its fields are safe to read once the kind matches.
 *
 * @field kind {string} always `"synology"` (`ERROR_KIND`)
 * @field message {string} `synology: ` and what failed, e.g. `SYNO.FileStation.List getinfo: no such file or directory (code 408)`
 * @field status {int} the HTTP status of a reply that was not 2xx; 0 otherwise
 * @field code {int} DSM's error code (`error.code`, or the entry's code for a File Station entry); 0 when DSM gave none
 */
export def struct SynologyError {
    kind as string,
    message as string,
    status as int,
    code as int
};

func fail(message as string) {
    failWith($message, 0, 0);
}

# failWith throws the SynologyError of a refusal, with its HTTP status and DSM code.
func failWith(message as string, status as int, code as int) {
    throw SynologyError{
        kind: ERROR_KIND,
        message: "synology: " + $message,
        status: $status,
        code: $code
    };
}

# failTransport throws the error of a request that got no usable answer: a
# reached cap (a `maxBytes` or `http` body cap) stays kind "limit", anything
# else is a SynologyError; the message is `synology: <what>: <cause>` either way.
func failTransport(what as string, e as Error) {
    if ($e.kind == "limit") {
        throw Error{kind: "limit", message: "synology: " + $what + ": " + $e.message};
    }
    fail($what + ": " + $e.message);
}

# How much of a string an error message repeats.
def const SHOWN as int init 60;

# The idle timeout a `timeoutMs` of 0 stands for, as `http.send` has it.
def const DEFAULT_TIMEOUT_MS as int init 30000;

# How long a `waitTimeoutMs` of 0 waits for a background task: one hour.
def const DEFAULT_WAIT_MS as int init 3600000;

/**
 * A string fit for an error message: cut to `most` characters, with
 * anything but printable ASCII as `?`, so a message stays one short line
 * and carries no line break or terminal escape into a log.
 *
 * @param text {string} a caller's or the host's string
 * @param most {int} the characters kept
 * @return {string} the text
 */
func plain(text as string, most as int) {
    def cut as string init $text;
    def more as string init "";
    if (len($text) > $most) {
        $cut = strings.substring($text, 0, $most);
        $more = "...";
    }
    return regex.replace("[^ -~]", $cut, "?") + $more;
}

/**
 * A string as an error message quotes it: `plain`, cut to `SHOWN`.
 *
 * @param text {string} a caller's or the host's string
 * @return {string} the text in double quotes
 */
func shown(text as string) {
    return "\"" + plain($text, SHOWN) + "\"";
}

/**
 * A refused HTTP status for an error message.
 *
 * @param status {int} the status
 * @param reason {string} the host's reason phrase
 * @return {string} e.g. `HTTP 502 Bad Gateway`
 */
func statusLine(status as int, reason as string) {
    return strings.trim("HTTP " + convert.toString($status) + " " +
        plain(strings.trim($reason), SHOWN));
}

/**
 * The base URL for a host name or URL. A bare host gets `https://` and port
 * 5001; a trailing slash and a trailing `/webapi` are dropped.
 *
 * @param address {string} `nas.example.com`, `10.0.0.5:5001` or `https://nas:5001/`
 * @return {string} `https://host:port`
 */
func baseUrl(address as string) {
    def url as string init strings.trim($address);
    if ($url == "") {
        fail("the host is empty");
    }
    while (strings.endsWith($url, "/")) {
        $url = strings.substring($url, 0, len($url) - 1);
    }
    if (strings.endsWith($url, "/webapi")) {
        $url = strings.substring($url, 0, len($url) - len("/webapi"));
    }
    if (strings.contains($url, "://")) {
        return $url;
    }
    if (not strings.startsWith($url, "[") and
        strings.indexOf($url, ":") != strings.lastIndexOf($url, ":")) {
        $url = "[" + $url + "]";
    }
    if (strings.contains($url, ":") and not strings.startsWith($url, "[")) {
        return "https://" + $url;
    }
    if (strings.startsWith($url, "[") and strings.contains($url, "]:")) {
        return "https://" + $url;
    }
    return "https://" + $url + ":" + convert.toString(DEFAULT_PORT);
}

/**
 * A client for a host, not logged in yet.
 *
 * @param address {string} host name, `host:port` or a full `https://` URL
 * @return {Client} the client; full certificate checking, session
 *   `FileStation`, 1 s task polling
 * @throws {SynologyError} kind `"synology"` when the address is empty
 * @example
 *   def c as synology.Client init synology.client("nas.example.com");
 */
export func client(address as string) {
    def c as Client;
    $c.url = baseUrl($address);
    $c.sessionName = "FileStation";
    $c.pollMs = 1000;
    return $c;
}

/**
 * Trust a certificate (PEM) in addition to the system's, such as the one
 * exported from DSM's Control Panel > Security > Certificate.
 *
 * @param c {Client} the client
 * @param pem {bytes} the certificate
 * @return {Client} the changed copy
 */
export func withCaCert(c as Client, pem as bytes) {
    $c.tls.caCert = $pem;
    $c.tls.skipVerify = false;
    return $c;
}

/**
 * Accept any certificate. The connection is still encrypted but no longer
 * authenticated; prefer `withCaCert`.
 *
 * @param c {Client} the client
 * @return {Client} the changed copy
 */
export func withInsecure(c as Client) {
    $c.tls.skipVerify = true;
    return $c;
}

/**
 * Set the idle timeout of each request.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds; 0 for the default, 30 s
 * @return {Client} the changed copy
 */
export func withTimeout(c as Client, ms as int) {
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * Retry a read answered 429 or 5xx. Writes are never retried: they need not
 * be idempotent.
 *
 * @param c {Client} the client
 * @param n {int} retries, 0 for none
 * @return {Client} the changed copy
 */
export func withRetries(c as Client, n as int) {
    $c.retries = $n;
    return $c;
}

/**
 * Set how often `copy`, `move`, `delete`, `createGuest` and `createImage`
 * ask about their background task.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds between checks; 0 for 1 s
 * @return {Client} the changed copy
 */
export func withPollInterval(c as Client, ms as int) {
    $c.pollMs = $ms;
    return $c;
}

/**
 * Set how long `copy`, `move`, `delete`, `createGuest` and `createImage`
 * wait for their background task before they fail with an `Error` of kind
 * `"timeout"`. The task itself goes on in DSM.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds; 0 for the default, 1 hour
 * @return {Client} the changed copy
 */
export func withWaitTimeout(c as Client, ms as int) {
    $c.waitTimeoutMs = $ms;
    return $c;
}

/**
 * Name the session `login` opens. DSM keeps one session per name and
 * account; a second login under the same name ends the first one.
 *
 * @param c {Client} the client
 * @param name {string} letters, digits, `_`, `.` and `-`
 * @return {Client} the changed copy
 * @throws {SynologyError} kind `"synology"` on another character
 */
export func withSessionName(c as Client, name as string) {
    if (not regex.matches("^[A-Za-z0-9_.-]+$", $name)) {
        fail("a session name is letters, digits, _, . and -, got " + shown($name));
    }
    $c.sessionName = $name;
    return $c;
}

/**
 * Use a session from an earlier `login`, for example one kept in a file.
 *
 * @param c {Client} the client
 * @param sid {string} the session id
 * @param synoToken {string} its `synotoken`, or "" when there is none
 * @return {Client} the changed copy
 * @throws {SynologyError} kind `"synology"` when either holds control characters
 */
export func withSession(c as Client, sid as string, synoToken as string) {
    if (regex.matches("[\\x00-\\x1f\\x7f]", $sid + $synoToken)) {
        fail("a session id and token hold no control characters");
    }
    $c.sid = $sid;
    $c.synoToken = $synoToken;
    return $c;
}

/**
 * Present a trusted device from an earlier `loginOtp`, so that the next
 * `login` needs no 2-step code. DSM wants the id with the name it was given
 * for.
 *
 * @param c {Client} the client
 * @param deviceId {string} the id `loginOtp` kept in `deviceId`
 * @param deviceName {string} the device name `loginOtp` was given
 * @return {Client} the changed copy
 */
export func withDeviceId(c as Client, deviceId as string, deviceName as string) {
    $c.deviceId = $deviceId;
    $c.deviceName = $deviceName;
    return $c;
}

/**
 * The idle timeout for the `http` calls that take it directly, where 0
 * would mean no timeout at all.
 *
 * @param c {Client} the client
 * @return {int} milliseconds
 */
func idleMs(c as Client) {
    if ($c.timeoutMs == 0) {
        return DEFAULT_TIMEOUT_MS;
    }
    return $c.timeoutMs;
}

/**
 * The delay between checks of a background task. Guards against a `Client`
 * declared without `client()`, whose `pollMs` 0 would ask without pause; it
 * waits a second instead.
 *
 * @param c {Client} the client
 * @return {int} milliseconds
 */
func pollDelay(c as Client) {
    if ($c.pollMs <= 0) {
        return 1000;
    }
    return $c.pollMs;
}

/**
 * How long to wait for a background task.
 *
 * @param c {Client} the client
 * @return {int} milliseconds; `DEFAULT_WAIT_MS` when `waitTimeoutMs` is 0
 */
func waitLimit(c as Client) {
    if ($c.waitTimeoutMs <= 0) {
        return DEFAULT_WAIT_MS;
    }
    return $c.waitTimeoutMs;
}

/**
 * Fail when a background task has run past the client's wait limit.
 *
 * @param c {Client} the client
 * @param what {string} the request that started it, for the error message
 * @param taskId {string} the task
 * @param started {time.Time} when the wait began
 * @throws {Error} kind `"timeout"` when the time is up: a deadline, the generic
 *   kind any library raises for one
 */
func checkWaited(c as Client, what as string, taskId as string, started as time.Time) {
    def limit as int init waitLimit($c);
    if (time.milliseconds(time.sub(time.now(), $started)) >= $limit) {
        throw Error{
            kind: "timeout",
            message: "synology: " + $what + ": task " + shown($taskId) + " still running after " +
                convert.toString($limit) + " ms"
        };
    }
}

/**
 * The request options for the client.
 *
 * @param c {Client} the client
 * @param readOnly {bool} whether the request may be retried
 * @return {http.Options} the options
 */
func optionsFor(c as Client, readOnly as bool) {
    def o as http.Options;
    $o.tls = $c.tls;
    $o.timeoutMs = $c.timeoutMs;
    if ($readOnly) {
        $o.maxRetries = $c.retries;
        $o.backoffMs = 500;
    }
    return $o;
}

/**
 * The headers of an API request.
 *
 * @param c {Client} the client
 * @return {map of string to string} the headers
 */
func requestHeaders(c as Client) {
    def headers as map of string to string init {"Accept": "application/json"};
    if ($c.synoToken != "") {
        $headers["X-SYNO-TOKEN"] = $c.synoToken;
    }
    return $headers;
}

/**
 * POST a form to a CGI under `/webapi` and return the decoded reply.
 *
 * @param c {Client} the client
 * @param cgi {string} e.g. `entry.cgi`
 * @param form {map of string to string} the fields, `api` and `method` included
 * @param readOnly {bool} whether the request may be retried
 * @return {json.Value} the whole reply
 * @throws {SynologyError} kind `"synology"` on a network failure, a status that is
 *   not 2xx or a reply that is not JSON
 */
func postForm(c as Client, cgi as string, form as map of string to string, readOnly as bool) {
    def what as string init $form["api"] + " " + $form["method"];
    def headers as map of string to string init requestHeaders($c);
    $headers["Content-Type"] = "application/x-www-form-urlencoded";
    def r as http.Response;
    try {
        $r = http.send(
            "POST",
            $c.url + "/webapi/" + $cgi,
            $headers,
            uri.buildQuery($form),
            optionsFor($c, $readOnly));
    } catch (e) {
        failTransport($what, $e);
    }
    if ($r.status < 200 or $r.status >= 300) {
        failWith($what + ": " + statusLine($r.status, $r.statusText), $r.status, 0);
    }
    return decodeReply($r.body, $what);
}

/**
 * Decode a reply body.
 *
 * @param body {string} the body
 * @param what {string} the request, for the error message
 * @return {json.Value} the reply
 */
func decodeReply(body as string, what as string) {
    def doc as json.Value;
    try {
        $doc = json.decode($body);
    } catch (e) {
        fail($what + ": the reply is not JSON");
    }
    if (kindAt($doc, "/success") != "bool") {
        fail($what + ": the reply has no success flag");
    }
    return $doc;
}

/**
 * The `data` of a reply, or the failure it reports.
 *
 * @param doc {json.Value} the reply
 * @param api {string} the API, which decides what its codes mean
 * @param what {string} the request, for the error message
 * @return {json.Value} `data`; JSON `null` when there is none
 * @throws {SynologyError} kind `"synology"` when the reply says `success: false`
 */
func dataOf(doc as json.Value, api as string, what as string) {
    if (not json.asBool($doc, "/success")) {
        failWith($what + ": " + failureText($doc, $api), 0, number($doc, "/error/code"));
    }
    if (not json.has($doc, "/data")) {
        return json.decode("null");
    }
    return json.get($doc, "/data");
}

/**
 * What a DSM error code means for an API.
 *
 * @param api {string} the API
 * @param code {int} the code
 * @return {string} the meaning; "unknown error code" when the guides list none
 */
func codeText(api as string, code as int) {
    def key as string init convert.toString($code);
    if ($code >= 400) {
        if ($api == "SYNO.API.Auth" and maps.has(AUTH_ERRORS, $key)) {
            return AUTH_ERRORS[$key];
        }
        if (strings.startsWith($api, "SYNO.FileStation.") and maps.has(FILE_ERRORS, $key)) {
            return FILE_ERRORS[$key];
        }
        if (strings.startsWith($api, "SYNO.Virtualization.") and maps.has(VMM_ERRORS, $key)) {
            return VMM_ERRORS[$key];
        }
    } elseif (maps.has(COMMON_ERRORS, $key)) {
        return COMMON_ERRORS[$key];
    }
    return "unknown error code";
}

/**
 * A code's meaning with the code.
 *
 * @param api {string} the API
 * @param code {int} the code
 * @return {string} e.g. `no such file or directory (code 408)`
 */
func coded(api as string, code as int) {
    return codeText($api, $code) + " (code " + convert.toString($code) + ")";
}

/**
 * Explain a reply with `success: false`: the code's meaning, and the path
 * and meaning of each entry in `error.errors`.
 *
 * @param doc {json.Value} the reply
 * @param api {string} the API
 * @return {string} e.g. `no such file or directory (code 408)`
 */
func failureText(doc as json.Value, api as string) {
    def code as int init number($doc, "/error/code");
    def text as string init coded($api, $code);
    def entries as string init entriesText($doc, "/error/errors", $api);
    if ($entries != "") {
        $text = $text + " [" + $entries + "]";
    }
    if ($code == 106 or $code == 107 or $code == 119) {
        $text = $text + "; log in again";
    }
    return $text;
}

/**
 * The entries of an `errors` list, each as `<path>: <meaning> (code <n>)`.
 *
 * @param doc {json.Value} the reply
 * @param ptr {string} the list's pointer
 * @param api {string} the API
 * @return {string} the entries joined by `; `; "" when there are none
 */
func entriesText(doc as json.Value, ptr as string, api as string) {
    def parts as list of string init [];
    for (def p in items($doc, $ptr)) {
        def code as int init number($doc, $p + "/code");
        def entry as string init coded($api, $code);
        def where as string init field($doc, $p + "/path");
        if ($where != "") {
            $entry = shown($where) + ": " + $entry;
        }
        $parts[] = $entry;
    }
    return strings.join($parts, "; ");
}

/**
 * Ask `SYNO.API.Info` about APIs.
 *
 * @param c {Client} the client
 * @param query {string} names, comma separated; a trailing `.` asks for a family
 * @return {map of string to ApiInfo} what the host knows of them
 */
func queryApis(c as Client, query as string) {
    def form as map of string to string init {
        "api": "SYNO.API.Info",
        "version": "1",
        "method": "query",
        "query": $query
    };
    def doc as json.Value init postForm($c, "query.cgi", $form, true);
    def data as json.Value init dataOf($doc, "SYNO.API.Info", "SYNO.API.Info query");
    def out as map of string to ApiInfo init {};
    if (json.typeOf($data) != "map") {
        return $out;
    }
    for (def name in json.keys($data)) {
        def p as string init "/" + pointerToken($name);
        def cgi as string init field($data, $p + "/path");
        if (not regex.matches(CGI_PATTERN, $cgi) or strings.contains($cgi, "..")) {
            fail("SYNO.API.Info gave " + shown($name) + " an unusable path " + shown($cgi));
        }
        $out[$name] = ApiInfo{
            name: $name,
            path: $cgi,
            minVersion: number($data, $p + "/minVersion"),
            maxVersion: number($data, $p + "/maxVersion"),
            requestFormat: strings.upper(field($data, $p + "/requestFormat"))
        };
    }
    return $out;
}

/**
 * Ask the host where the deck's APIs live: `SYNO.API.Auth`, `SYNO.DSM.Info`,
 * the `SYNO.FileStation.*` and `SYNO.Virtualization.API.*` families, and the
 * `SYNO.Core` (and `SYNO.Storage`, `SYNO.Backup`) APIs of the typed verbs.
 * `login` does this first; call it yourself after `withSession`.
 *
 * @param c {Client} the client
 * @return {Client} the copy that knows them
 * @throws {SynologyError} kind `"synology"` when the host does not answer as DSM
 */
export func discover(c as Client) {
    $c.apis = queryApis($c, KNOWN_APIS);
    if (not maps.has($c.apis, "SYNO.API.Auth")) {
        fail("the host lists no SYNO.API.Auth; is it DSM?");
    }
    return $c;
}

/**
 * Where an API lives and which versions the host speaks. The deck's own APIs
 * come from what `discover` found; any other is asked for.
 *
 * @param c {Client} the client
 * @param api {string} e.g. `SYNO.Core.System`
 * @return {ApiInfo} the API
 * @throws {SynologyError} kind `"synology"` when the host does not have it
 */
export func apiInfo(c as Client, api as string) {
    if (maps.has($c.apis, $api)) {
        return $c.apis[$api];
    }
    if (not regex.matches("^SYNO\\.[A-Za-z0-9_.]+$", $api) or strings.endsWith($api, ".")) {
        fail("an API name is SYNO.<name>, got " + shown($api));
    }
    def found as map of string to ApiInfo init queryApis($c, $api);
    if (not maps.has($found, $api)) {
        fail("the host has no " + $api);
    }
    return $found[$api];
}

/**
 * The version to speak: the one the deck was written for, or the host's
 * newest when that is older, but never below what the deck needs.
 *
 * @param spec {ApiInfo} the API
 * @param wanted {int} the version the deck was written for
 * @param lowest {int} the oldest version the deck can use
 * @return {int} the version
 */
func versionFor(spec as ApiInfo, wanted as int, lowest as int) {
    def v as int init $wanted;
    if ($v > $spec.maxVersion) {
        $v = $spec.maxVersion;
    }
    if ($v < $spec.minVersion or $v < $lowest) {
        fail(
            $spec.name + ": the host speaks versions " + convert.toString($spec.minVersion) +
                " to " + convert.toString($spec.maxVersion) + ", the deck needs " +
                convert.toString($lowest) + " to " + convert.toString($wanted));
    }
    return $v;
}

/**
 * Parameters for an API whose `requestFormat` is `JSON`: each value JSON.
 * A value that already is JSON (a number, `true`, a list, an object, a
 * quoted string) goes as it is; anything else as a JSON string.
 *
 * @param params {map of string to string} the parameters
 * @return {map of string to string} the encoded parameters
 */
func jsonValues(params as map of string to string) {
    def out as map of string to string init {};
    for (def key in maps.keys($params)) {
        def value as string init $params[$key];
        def isJson as bool init true;
        try {
            json.decode($value);
        } catch (e) {
            $isJson = false;
        }
        if ($isJson) {
            $out[$key] = $value;
        } else {
            $out[$key] = json.encode($value);
        }
    }
    return $out;
}

/**
 * Send one API request with the session.
 *
 * @param c {Client} the client
 * @param spec {ApiInfo} the API, from `apiInfo`
 * @param version {int} the version
 * @param method {string} the method
 * @param params {map of string to string} the parameters
 * @param readOnly {bool} whether the request may be retried
 * @return {json.Value} the whole reply
 */
func send(
    c as Client,
    spec as ApiInfo,
    version as int,
    method as string,
    params as map of string to string,
    readOnly as bool) {
    def form as map of string to string init $params;
    if ($spec.requestFormat == "JSON") {
        $form = jsonValues($params);
    }
    $form["api"] = $spec.name;
    $form["version"] = convert.toString($version);
    $form["method"] = $method;
    if ($c.sid != "") {
        $form["_sid"] = $c.sid;
    }
    return postForm($c, $spec.path, $form, $readOnly);
}

/**
 * Call a method of a typed API and return its `data`.
 *
 * @param c {Client} the client
 * @param api {string} the API
 * @param wanted {int} the version the deck was written for
 * @param lowest {int} the oldest version the deck can use
 * @param method {string} the method
 * @param params {map of string to string} the parameters
 * @param readOnly {bool} whether the request may be retried
 * @return {json.Value} the reply's `data`
 */
func request(
    c as Client,
    api as string,
    wanted as int,
    lowest as int,
    method as string,
    params as map of string to string,
    readOnly as bool) {
    def spec as ApiInfo init apiInfo($c, $api);
    def v as int init versionFor($spec, $wanted, $lowest);
    def doc as json.Value init send($c, $spec, $v, $method, $params, $readOnly);
    return dataOf($doc, $api, $api + " " + $method);
}

/**
 * Call any method of any API. Parameters that DSM takes as JSON, such as a
 * list of paths, are passed already encoded (`json.encode(["/a", "/b"])`).
 *
 * @param c {Client} the client
 * @param api {string} e.g. `SYNO.Core.System`
 * @param version {int} the version; 0 for the newest the host speaks
 * @param method {string} e.g. `info`
 * @param params {map of string to string} the parameters; `{}` for none
 * @return {json.Value} the reply's `data`; JSON `null` when there is none
 * @throws {SynologyError} kind `"synology"` when the host lacks the API or version,
 *   on a network failure, or when DSM reports an error
 * @example
 *   def u as json.Value init synology.call($c, "SYNO.Core.System.Utilization", 1, "get", {});
 */
export func call(
    c as Client,
    api as string,
    version as int,
    method as string,
    params as map of string to string) {
    def spec as ApiInfo init apiInfo($c, $api);
    def v as int init $version;
    if ($v == 0) {
        $v = $spec.maxVersion;
    }
    if ($v < $spec.minVersion or $v > $spec.maxVersion) {
        fail(
            $api + ": the host speaks versions " + convert.toString($spec.minVersion) +
                " to " + convert.toString($spec.maxVersion) + ", not " + convert.toString($v));
    }
    def doc as json.Value init send($c, $spec, $v, $method, $params, false);
    return dataOf($doc, $api, $api + " " + $method);
}

/**
 * Log in and keep the session. Discovers the host's APIs first when the
 * client does not know them yet.
 *
 * @param c {Client} the client
 * @param account {string} the DSM account
 * @param password {string} its password
 * @param extra {map of string to string} more login fields
 * @return {Client} the logged-in copy
 */
func authenticate(
    c as Client,
    account as string,
    password as string,
    extra as map of string to string) {
    if (not maps.has($c.apis, "SYNO.API.Auth")) {
        $c = discover($c);
    }
    $c.sid = "";
    $c.synoToken = "";
    def params as map of string to string init $extra;
    $params["account"] = $account;
    $params["passwd"] = $password;
    $params["session"] = $c.sessionName;
    $params["format"] = "sid";
    $params["enable_syno_token"] = "yes";
    if ($c.deviceId != "" and not maps.has($params, "otp_code")) {
        $params["device_id"] = $c.deviceId;
        if ($c.deviceName != "") {
            $params["device_name"] = $c.deviceName;
        }
    }
    def data as json.Value;
    try {
        $data = request($c, "SYNO.API.Auth", 6, 3, "login", $params, false);
    } catch (e) {
        # DSM code 403: the account needs a one-time code
        if ($e.kind == ERROR_KIND and $e.code == 403) {
            throw SynologyError{
                kind: ERROR_KIND,
                message: $e.message + "; use loginOtp",
                status: $e.status,
                code: $e.code
            };
        }
        throw $e;
    }
    def sid as string init field($data, "/sid");
    if ($sid == "") {
        fail("SYNO.API.Auth login: the reply has no sid");
    }
    return finishLogin($c, $data);
}

/**
 * Keep what a login reply hands out.
 *
 * @param c {Client} the client
 * @param data {json.Value} the login reply's `data`
 * @return {Client} the copy holding the session
 */
func finishLogin(c as Client, data as json.Value) {
    $c = withSession($c, field($data, "/sid"), field($data, "/synotoken"));
    def did as string init field($data, "/did");
    if ($did != "") {
        $c.deviceId = $did;
    }
    return $c;
}

/**
 * Ask for a new CSRF token (`SynoToken`) for the session, as after
 * `withSession` with a sid alone.
 *
 * @param c {Client} the client
 * @return {Client} the copy holding the token
 * @throws {SynologyError} kind `"synology"` when the session is gone, or as `call`
 */
export func refreshToken(c as Client) {
    def d as json.Value init request($c, "SYNO.API.Auth", 6, 6, "token", {}, true);
    def token as string init field($d, "/synotoken");
    if ($token == "") {
        fail("SYNO.API.Auth token: the reply has no synotoken");
    }
    return withSession($c, $c.sid, $token);
}

/**
 * Log in with an account and password and keep the session.
 *
 * @param c {Client} the client
 * @param account {string} the DSM account
 * @param password {string} its password
 * @return {Client} the copy holding the session
 * @throws {SynologyError} kind `"synology"` when the login is refused, or when the
 *   account needs a 2-step code (use `loginOtp`)
 * @example
 *   $c = synology.login($c, "backup", "secret");
 */
export func login(c as Client, account as string, password as string) {
    return authenticate($c, $account, $password, {});
}

/**
 * Log in with a 2-step verification code. With a device name, DSM trusts
 * this device: `deviceId` then holds an id that lets a later `login`, after
 * `withDeviceId`, skip the code.
 *
 * @param c {Client} the client
 * @param account {string} the DSM account
 * @param password {string} its password
 * @param code {string} the current code from the authenticator
 * @param deviceName {string} a name for this device, or "" to trust nothing
 * @return {Client} the copy holding the session
 * @throws {SynologyError} kind `"synology"` when the login or the code is refused
 */
export func loginOtp(
    c as Client,
    account as string,
    password as string,
    code as string,
    deviceName as string) {
    def extra as map of string to string init {"otp_code": strings.trim($code)};
    if ($deviceName != "") {
        $extra["enable_device_token"] = "yes";
        $extra["device_name"] = $deviceName;
        $c.deviceName = $deviceName;
    }
    return authenticate($c, $account, $password, $extra);
}

/**
 * End the session.
 *
 * @param c {Client} the client
 * @return {Client} the copy without a session
 * @throws {SynologyError} kind `"synology"` when DSM refuses
 */
export func logout(c as Client) {
    if ($c.sid == "") {
        return $c;
    }
    request($c, "SYNO.API.Auth", 6, 1, "logout", {"session": $c.sessionName}, false);
    $c.sid = "";
    $c.synoToken = "";
    return $c;
}

/**
 * The host's model, DSM version, memory, uptime and temperature.
 *
 * @param c {Client} the client
 * @return {SystemInfo} the summary
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func info(c as Client) {
    def d as json.Value init request($c, "SYNO.DSM.Info", 2, 1, "getinfo", {}, true);
    return SystemInfo{
        model: field($d, "/model"),
        serial: field($d, "/serial"),
        version: field($d, "/version_string"),
        build: field($d, "/version"),
        ramMb: number($d, "/ram"),
        uptime: number($d, "/uptime"),
        temperature: number($d, "/temperature"),
        overheated: flag($d, "/temperature_warn")
    };
}

/**
 * Refuse a path File Station would not take as meant.
 *
 * @param path {string} the path
 * @return {string} the path without a trailing slash
 */
func checkPath(path as string) {
    def p as string init $path;
    while (len($p) > 1 and strings.endsWith($p, "/")) {
        $p = strings.substring($p, 0, len($p) - 1);
    }
    if (not strings.startsWith($p, "/") or $p == "/") {
        fail("a File Station path starts with /<share>, got " + shown($path));
    }
    if (regex.matches("[\\x00-\\x1f\\x7f]", $p)) {
        fail("a path holds no control characters");
    }
    for (def segment in strings.split(strings.substring($p, 1), "/")) {
        if ($segment == "" or $segment == "." or $segment == "..") {
            fail("a path has no empty, . or .. segments, got " + shown($path));
        }
    }
    return $p;
}

/**
 * Refuse a file or folder name.
 *
 * @param name {string} the name
 */
func checkName(name as string) {
    if ($name == "" or $name == "." or $name == ".." or strings.contains($name, "/") or
        regex.matches("[\\x00-\\x1f\\x7f]", $name)) {
        fail("a name holds no /, no control characters and is not . or .., got " + shown($name));
    }
}

/**
 * The folder holding a path.
 *
 * @param path {string} a checked path
 * @return {string} the parent; for `/share/a` it is `/share`
 */
func parentOf(path as string) {
    return strings.substring($path, 0, strings.lastIndexOf($path, "/"));
}

/**
 * The last segment of a path.
 *
 * @param path {string} a checked path
 * @return {string} the name
 */
func nameOf(path as string) {
    return strings.substring($path, strings.lastIndexOf($path, "/") + 1);
}

/**
 * A File Station entry.
 *
 * @param d {json.Value} the reply
 * @param p {string} the entry's pointer
 * @return {File} the file
 */
func fileFrom(d as json.Value, p as string) {
    return File{
        name: field($d, $p + "/name"),
        path: field($d, $p + "/path"),
        isDir: flag($d, $p + "/isdir"),
        size: number($d, $p + "/additional/size"),
        modified: number($d, $p + "/additional/time/mtime")
    };
}

/**
 * The shared folders the account can see.
 *
 * @param c {Client} the client
 * @return {list of Share} the shares
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func shares(c as Client) {
    def out as list of Share init [];
    def offset as int init 0;
    def more as bool init true;
    while ($more) {
        def d as json.Value init request(
            $c,
            "SYNO.FileStation.List",
            2,
            2,
            "list_share",
            {
                "offset": convert.toString($offset),
                "limit": convert.toString(PAGE_SIZE),
                "additional": json.encode(["real_path", "volume_status"])
            },
            true);
        def page as list of string init items($d, "/shares");
        for (def p in $page) {
            $out[] = Share{
                name: field($d, $p + "/name"),
                path: field($d, $p + "/path"),
                realPath: field($d, $p + "/additional/real_path"),
                free: number($d, $p + "/additional/volume_status/freespace"),
                total: number($d, $p + "/additional/volume_status/totalspace"),
                readOnly: flag($d, $p + "/additional/volume_status/readonly")
            };
        }
        $offset = $offset + len($page);
        $more = len($page) > 0 and $offset < number($d, "/total");
    }
    return $out;
}

/**
 * The files and folders in a folder, folders first, by name.
 *
 * @param c {Client} the client
 * @param folder {string} e.g. `/photo/2024`
 * @return {list of File} the entries
 * @throws {SynologyError} kind `"synology"` on a bad path, a missing folder or as `call`
 * @example
 *   for (def f in synology.files($c, "/photo")) {
 *       io.printf("%s\n", $f.path);
 *   }
 */
export func files(c as Client, folder as string) {
    def path as string init checkPath($folder);
    def out as list of File init [];
    def offset as int init 0;
    def more as bool init true;
    while ($more) {
        def d as json.Value init request(
            $c,
            "SYNO.FileStation.List",
            2,
            2,
            "list",
            {
                "folder_path": $path,
                "offset": convert.toString($offset),
                "limit": convert.toString(PAGE_SIZE),
                "sort_by": "name",
                "additional": json.encode(["size", "time"])
            },
            true);
        def page as list of string init items($d, "/files");
        for (def p in $page) {
            $out[] = fileFrom($d, $p);
        }
        $offset = $offset + len($page);
        $more = len($page) > 0 and $offset < number($d, "/total");
    }
    return $out;
}

/**
 * Ask `getinfo` about one path.
 *
 * @param c {Client} the client
 * @param path {string} a checked path
 * @return {json.Value} the whole reply
 */
func getinfo(c as Client, path as string) {
    def spec as ApiInfo init apiInfo($c, "SYNO.FileStation.List");
    def v as int init versionFor($spec, 2, 2);
    return send(
        $c,
        $spec,
        $v,
        "getinfo",
        {"path": json.encode([$path]), "additional": json.encode(["size", "time"])},
        true);
}

/**
 * The code a `getinfo` reply gives its first entry; DSM reports a missing
 * path there, with `success: true`.
 *
 * @param doc {json.Value} the reply
 * @return {int} the code; 0 when there is none
 */
func entryCode(doc as json.Value) {
    return number($doc, "/data/files/0/code");
}

/**
 * One file or folder.
 *
 * @param c {Client} the client
 * @param path {string} e.g. `/photo/a.jpg`
 * @return {File} the entry
 * @throws {SynologyError} kind `"synology"` when it does not exist or as `call`
 */
export func stat(c as Client, path as string) {
    def p as string init checkPath($path);
    def doc as json.Value init getinfo($c, $p);
    def d as json.Value init dataOf($doc, "SYNO.FileStation.List", "SYNO.FileStation.List getinfo");
    def code as int init entryCode($doc);
    if ($code != 0) {
        failWith(
            "SYNO.FileStation.List getinfo: " + $p + ": " + coded("SYNO.FileStation.List", $code),
            0,
            $code);
    }
    if (len(items($d, "/files")) == 0) {
        fail("SYNO.FileStation.List getinfo: no entry for " + $p);
    }
    return fileFrom($d, "/files/0");
}

/**
 * Whether a file or folder exists.
 *
 * @param c {Client} the client
 * @param path {string} e.g. `/photo/a.jpg`
 * @return {bool} whether it exists
 * @throws {SynologyError} kind `"synology"` on a bad path or any other failure
 */
export func exists(c as Client, path as string) {
    def p as string init checkPath($path);
    def doc as json.Value init getinfo($c, $p);
    if (not json.asBool($doc, "/success")) {
        if (number($doc, "/error/code") == 408) {
            return false;
        }
        dataOf($doc, "SYNO.FileStation.List", "SYNO.FileStation.List getinfo");
    }
    def code as int init entryCode($doc);
    if ($code == 408) {
        return false;
    }
    if ($code != 0) {
        failWith(
            "SYNO.FileStation.List getinfo: " + $p + ": " + coded("SYNO.FileStation.List", $code),
            0,
            $code);
    }
    return true;
}

/**
 * Create a folder.
 *
 * @param c {Client} the client
 * @param path {string} the new folder, e.g. `/backup/2024/06`
 * @param parents {bool} create missing parent folders too; an existing
 *   folder is then no error
 * @return {File} the folder
 * @throws {SynologyError} kind `"synology"` on a bad path or when DSM refuses
 */
export func mkdir(c as Client, path as string, parents as bool) {
    def p as string init checkPath($path);
    if (not strings.contains(strings.substring($p, 1), "/")) {
        fail("a shared folder is not created through File Station: " + $p);
    }
    def d as json.Value init request(
        $c,
        "SYNO.FileStation.CreateFolder",
        2,
        1,
        "create",
        {
            "folder_path": json.encode([parentOf($p)]),
            "name": json.encode([nameOf($p)]),
            "force_parent": convert.toString($parents)
        },
        false);
    if (len(items($d, "/folders")) == 0) {
        return File{name: nameOf($p), path: $p, isDir: true, size: 0, modified: 0};
    }
    return fileFrom($d, "/folders/0");
}

/**
 * Rename a file or folder in place.
 *
 * @param c {Client} the client
 * @param path {string} what to rename
 * @param name {string} the new name, without a folder
 * @return {File} the renamed entry
 * @throws {SynologyError} kind `"synology"` on a bad path or name or when DSM refuses
 */
export func rename(c as Client, path as string, name as string) {
    def p as string init checkPath($path);
    checkName($name);
    def d as json.Value init request(
        $c,
        "SYNO.FileStation.Rename",
        2,
        1,
        "rename",
        {"path": json.encode([$p]), "name": json.encode([$name])},
        false);
    if (len(items($d, "/files")) == 0) {
        return File{
            name: $name,
            path: parentOf($p) + "/" + $name,
            isDir: false,
            size: 0,
            modified: 0
        };
    }
    return fileFrom($d, "/files/0");
}

/**
 * Wait for a File Station background task to finish, checking every
 * `pollDelay` for at most `waitLimit`.
 *
 * @param c {Client} the client
 * @param spec {ApiInfo} the task's API
 * @param version {int} the version it was started with
 * @param taskId {string} the id `start` returned
 * @return {json.Value} the last status
 * @throws {SynologyError} kind `"synology"` when the task reports errors or the
 *   time runs out
 */
func waitFor(c as Client, spec as ApiInfo, version as int, taskId as string) {
    def started as time.Time init time.now();
    def api as string init $spec.name;
    def d as json.Value init json.decode("null");
    def done as bool init false;
    while (not $done) {
        def doc as json.Value init send($c, $spec, $version, "status", {"taskid": $taskId}, true);
        $d = dataOf($doc, $api, $api + " status");
        def entries as string init entriesText($d, "/errors", $api);
        if ($entries != "") {
            fail($api + ": " + $entries);
        }
        $done = flag($d, "/finished");
        if (not $done) {
            checkWaited($c, $api, $taskId, $started);
            time.sleep(time.fromMilliseconds(pollDelay($c)));
        }
    }
    return $d;
}

/**
 * Start a background task and wait for it.
 *
 * @param c {Client} the client
 * @param api {string} the API
 * @param wanted {int} the version the deck was written for
 * @param params {map of string to string} the `start` parameters
 * @return {json.Value} the last status
 */
func runTask(c as Client, api as string, wanted as int, params as map of string to string) {
    def spec as ApiInfo init apiInfo($c, $api);
    def v as int init versionFor($spec, $wanted, $wanted);
    def doc as json.Value init send($c, $spec, $v, "start", $params, false);
    def d as json.Value init dataOf($doc, $api, $api + " start");
    def taskId as string init field($d, "/taskid");
    if ($taskId == "") {
        fail($api + " start: the reply has no taskid");
    }
    return waitFor($c, $spec, $v, $taskId);
}

/**
 * Delete a file, or a folder with everything in it. Waits until DSM is done.
 *
 * @param c {Client} the client
 * @param path {string} what to delete
 * @throws {SynologyError} kind `"synology"` on a bad path or when DSM refuses
 */
export func delete(c as Client, path as string) {
    def p as string init checkPath($path);
    if (not strings.contains(strings.substring($p, 1), "/")) {
        fail("a shared folder is not deleted through File Station: " + $p);
    }
    runTask($c, "SYNO.FileStation.Delete", 2, {"path": json.encode([$p]), "recursive": "true"});
}

/**
 * Copy or move into a folder.
 *
 * @param c {Client} the client
 * @param path {string} the source
 * @param folder {string} the destination folder
 * @param overwrite {bool} replace an existing entry of the same name
 * @param removeSource {bool} move instead of copy
 * @return {string} the new path
 */
func transfer(
    c as Client,
    path as string,
    folder as string,
    overwrite as bool,
    removeSource as bool) {
    def p as string init checkPath($path);
    def dest as string init checkPath($folder);
    def params as map of string to string init {
        "path": json.encode([$p]),
        "dest_folder_path": $dest,
        "remove_src": convert.toString($removeSource)
    };
    if ($overwrite) {
        $params["overwrite"] = "true";
    }
    runTask($c, "SYNO.FileStation.CopyMove", 3, $params);
    return $dest + "/" + nameOf($p);
}

/**
 * Copy a file or folder into another folder. Waits until DSM is done.
 *
 * @param c {Client} the client
 * @param path {string} what to copy
 * @param folder {string} the destination folder
 * @param overwrite {bool} replace an existing entry of the same name; when
 *   false, an existing one is an error
 * @return {string} the path of the copy
 * @throws {SynologyError} kind `"synology"` on a bad path or when DSM refuses
 */
export func copy(c as Client, path as string, folder as string, overwrite as bool) {
    return transfer($c, $path, $folder, $overwrite, false);
}

/**
 * Move a file or folder into another folder. Waits until DSM is done.
 *
 * @param c {Client} the client
 * @param path {string} what to move
 * @param folder {string} the destination folder
 * @param overwrite {bool} replace an existing entry of the same name; when
 *   false, an existing one is an error
 * @return {string} the new path
 * @throws {SynologyError} kind `"synology"` on a bad path or when DSM refuses
 */
export func move(c as Client, path as string, folder as string, overwrite as bool) {
    return transfer($c, $path, $folder, $overwrite, true);
}

/**
 * Upload a file into a folder, creating missing folders.
 *
 * @param c {Client} the client
 * @param folder {string} the destination folder
 * @param name {string} the file name
 * @param data {bytes} the content
 * @param overwrite {bool} replace an existing file; when false, an existing
 *   one is an error
 * @return {string} the file's path
 * @throws {SynologyError} kind `"synology"` on a bad path or name, a network failure
 *   or when DSM refuses
 * @example
 *   synology.upload($c, "/backup", "db.sql.gz", fs.readBytes("db.sql.gz"), true);
 */
export func upload(
    c as Client,
    folder as string,
    name as string,
    data as bytes,
    overwrite as bool) {
    def dest as string init checkPath($folder);
    checkName($name);
    def spec as ApiInfo init apiInfo($c, "SYNO.FileStation.Upload");
    def parts as list of multipart.Part init [
        multipart.field("path", $dest),
        multipart.field("create_parents", "true")
    ];
    if ($overwrite) {
        $parts[] = multipart.field("overwrite", "true");
    }
    $parts[] = multipart.file("file", $name, "application/octet-stream", $data);
    postParts($c, $spec, versionFor($spec, 2, 2), "upload", $parts);
    return $dest + "/" + $name;
}

/**
 * POST a multipart form, with `api`, `version`, `method` and `_sid` in the
 * URL: the form the upload APIs take.
 *
 * @param c {Client} the client
 * @param spec {ApiInfo} the API
 * @param version {int} the version
 * @param method {string} the method
 * @param parts {list of multipart.Part} the form, files last
 * @return {json.Value} the reply's `data`
 */
func postParts(
    c as Client,
    spec as ApiInfo,
    version as int,
    method as string,
    parts as list of multipart.Part) {
    def query as map of string to string init {
        "api": $spec.name,
        "version": convert.toString($version),
        "method": $method
    };
    if ($c.sid != "") {
        $query["_sid"] = $c.sid;
    }
    def built as multipart.Built init multipart.build($parts);
    def headers as map of string to string init requestHeaders($c);
    $headers["Content-Type"] = $built.contentType;
    def what as string init $spec.name + " " + $method;
    def r as http.Response;
    try {
        $r = http.requestRawBodyTls(
            "POST",
            $c.url + "/webapi/" + $spec.path + "?" + uri.buildQuery($query),
            $headers,
            $built.body,
            idleMs($c),
            0,
            $c.tls);
    } catch (e) {
        failTransport($what, $e);
    }
    if ($r.status < 200 or $r.status >= 300) {
        failWith($what + ": " + statusLine($r.status, $r.statusText), $r.status, 0);
    }
    return dataOf(decodeReply($r.body, $what), $spec.name, $what);
}

/**
 * Download a file. A folder comes as a zip archive.
 *
 * @param c {Client} the client
 * @param path {string} the file
 * @param maxBytes {int} the largest reply accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the content
 * @throws {SynologyError} kind `"synology"` on a bad path, a network failure
 *   or when DSM refuses
 * @throws {Error} kind `"limit"` for a reply over `maxBytes`
 */
export func download(c as Client, path as string, maxBytes as int) {
    def p as string init checkPath($path);
    def api as string init "SYNO.FileStation.Download";
    def spec as ApiInfo init apiInfo($c, $api);
    def form as map of string to string init {
        "api": $api,
        "version": convert.toString(versionFor($spec, 2, 2)),
        "method": "download",
        "path": json.encode([$p]),
        "mode": "download"
    };
    if ($c.sid != "") {
        $form["_sid"] = $c.sid;
    }
    def headers as map of string to string init requestHeaders($c);
    $headers["Accept"] = "*/*";
    $headers["Content-Type"] = "application/x-www-form-urlencoded";
    def what as string init $api + " download";
    def r as http.BytesResponse;
    try {
        $r = http.requestWithBytes(
            "POST",
            $c.url + "/webapi/" + $spec.path,
            $headers,
            uri.buildQuery($form),
            idleMs($c),
            $maxBytes,
            $c.tls);
    } catch (e) {
        failTransport($what, $e);
    }
    if ($r.status < 200 or $r.status >= 300) {
        failWith($what + ": " + statusLine($r.status, $r.statusText), $r.status, 0);
    }
    # A refusal comes as a JSON reply instead of the file.
    def contentType as string init "";
    if (maps.has($r.headers, "content-type")) {
        $contentType = strings.lower($r.headers["content-type"]);
    }
    if (strings.startsWith($contentType, "application/json")) {
        def doc as json.Value init decodeReply(convert.stringFromBytes("utf-8", $r.body), $what);
        dataOf($doc, $api, $what);
    }
    return $r.body;
}

# The version of the Virtual Machine Manager APIs the deck was written for.
def const VMM_VERSION as int init 1;

/**
 * Refuse a name of a virtual machine, image, storage, network, user, group or
 * share. The Virtual Machine Manager guide escapes `,` and `\` in
 * parameters; the deck refuses them instead of sending an escape it cannot
 * check (DSM allows neither in account or share names).
 *
 * @param name {string} the name
 * @param what {string} what it names, for the error message
 * @return {string} the name
 */
func checkLabel(name as string, what as string) {
    if (strings.trim($name) == "" or regex.matches("[\\x00-\\x1f\\x7f,\\\\]", $name)) {
        fail("a " + $what + " name is not empty and holds no comma, backslash or control " +
            "characters, got " + shown($name));
    }
    return $name;
}

/**
 * Call a Virtual Machine Manager method and return its `data`.
 *
 * @param c {Client} the client
 * @param api {string} the API, after `SYNO.Virtualization.API.`
 * @param method {string} the method
 * @param params {map of string to string} the parameters
 * @param readOnly {bool} whether the request may be retried
 * @return {json.Value} the reply's `data`
 */
func vmm(
    c as Client,
    api as string,
    method as string,
    params as map of string to string,
    readOnly as bool) {
    return request(
        $c,
        "SYNO.Virtualization.API." + $api,
        VMM_VERSION,
        VMM_VERSION,
        $method,
        $params,
        $readOnly);
}

/**
 * A virtual machine from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the guest's pointer; "" for the root
 * @return {Guest} the guest
 */
func guestFrom(d as json.Value, p as string) {
    def disks as list of VDisk init [];
    for (def q in items($d, $p + "/vdisks")) {
        $disks[] = VDisk{
            id: field($d, $q + "/vdisk_id"),
            sizeMb: number($d, $q + "/vdisk_size"),
            controller: number($d, $q + "/controller"),
            unmap: flag($d, $q + "/unmap")
        };
    }
    def nics as list of VNic init [];
    for (def q in items($d, $p + "/vnics")) {
        $nics[] = VNic{
            id: field($d, $q + "/vnic_id"),
            mac: field($d, $q + "/mac"),
            model: number($d, $q + "/model"),
            networkId: field($d, $q + "/network_id"),
            networkName: field($d, $q + "/network_name")
        };
    }
    return Guest{
        id: field($d, $p + "/guest_id"),
        name: field($d, $p + "/guest_name"),
        description: field($d, $p + "/description"),
        status: field($d, $p + "/status"),
        autorun: number($d, $p + "/autorun"),
        storageId: field($d, $p + "/storage_id"),
        storageName: field($d, $p + "/storage_name"),
        vcpus: number($d, $p + "/vcpu_num"),
        ramMb: number($d, $p + "/vram_size"),
        disks: $disks,
        nics: $nics
    };
}

/**
 * The virtual machines of Virtual Machine Manager.
 *
 * @param c {Client} the client
 * @return {list of Guest} the virtual machines
 * @throws {SynologyError} kind `"synology"` when Virtual Machine Manager is not
 *   installed, or as `call`
 * @example
 *   for (def g in synology.guests($c)) {
 *       io.printf("%s %s\n", $g.name, $g.status);
 *   }
 */
export func guests(c as Client) {
    def d as json.Value init vmm($c, "Guest", "list", {"additional": "true"}, true);
    def out as list of Guest init [];
    for (def p in items($d, "/guests")) {
        $out[] = guestFrom($d, $p);
    }
    return $out;
}

/**
 * One virtual machine.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @return {Guest} the virtual machine
 * @throws {SynologyError} kind `"synology"` when there is none of that name, or as
 *   `call`
 */
export func guest(c as Client, name as string) {
    def params as map of string to string init {
        "guest_name": checkLabel($name, "virtual machine"),
        "additional": "true"
    };
    return guestFrom(vmm($c, "Guest", "get", $params, true), "");
}

/**
 * Wait for a Virtual Machine Manager task and return its `task_info`,
 * checking every `pollDelay` (at most 30 s) for at most `waitLimit`.
 *
 * @param c {Client} the client
 * @param what {string} the request that started it, for the error message
 * @param start {json.Value} the `data` of the request that started it
 * @return {json.Value} the finished task's `task_info`
 * @throws {SynologyError} kind `"synology"` when the reply has no task id or the
 *   time runs out
 */
func waitVm(c as Client, what as string, start as json.Value) {
    def started as time.Time init time.now();
    def taskId as string init field($start, "/task_id");
    if ($taskId == "") {
        fail($what + ": the reply has no task_id");
    }
    # VMM drops a finished task's record after about a minute.
    def pause as int init pollDelay($c);
    if ($pause > 30000) {
        $pause = 30000;
    }
    def d as json.Value init json.decode("null");
    def done as bool init false;
    while (not $done) {
        $d = vmm($c, "Task.Info", "get", {"task_id": $taskId}, true);
        $done = flag($d, "/finish");
        if (not $done) {
            checkWaited($c, $what, $taskId, $started);
            time.sleep(time.fromMilliseconds($pause));
        }
    }
    if (not json.has($d, "/task_info")) {
        return json.decode('{}');
    }
    return json.get($d, "/task_info");
}

/**
 * Create a virtual machine and wait until it exists. It is left powered
 * off; `powerOnGuest` starts it.
 *
 * @param c {Client} the client
 * @param spec {GuestSpec} what to create
 * @return {Guest} the new virtual machine
 * @throws {SynologyError} kind `"synology"` on a bad name, a disk without a size or
 *   image, or when Virtual Machine Manager refuses
 * @example
 *   def spec as synology.GuestSpec init synology.GuestSpec{
 *       name: "web01",
 *       storage: "Synology - VM Storage 1",
 *       disks: [synology.DiskSpec{sizeMb: 0, image: "debian-12"}],
 *       networks: ["Default VM Network"],
 *       vcpus: 2,
 *       ramMb: 2048
 *   };
 *   synology.powerOnGuest($c, synology.createGuest($c, $spec).name);
 */
export func createGuest(c as Client, spec as GuestSpec) {
    checkLabel($spec.name, "virtual machine");
    checkLabel($spec.storage, "storage");
    if (len($spec.disks) == 0) {
        fail("a virtual machine needs a disk");
    }
    def disks as json.Value init json.decode("[]");
    for (def disk in $spec.disks) {
        def entry as json.Value init json.decode('{"create_type":0}');
        if ($disk.image != "") {
            $entry = json.set($entry, "/create_type", 1);
            $entry = json.set($entry, "/image_name", checkLabel($disk.image, "image"));
        } elseif ($disk.sizeMb > 0) {
            $entry = json.set($entry, "/vdisk_size", $disk.sizeMb);
        } else {
            fail("a disk has a size or an image");
        }
        $disks = json.insert($disks, "/-", $entry);
    }
    def nics as json.Value init json.decode("[]");
    for (def network in $spec.networks) {
        def entry as json.Value init json.decode('{"network_id":""}');
        if ($network != "") {
            $entry = json.decode('{"network_name":""}');
            $entry = json.set($entry, "/network_name", checkLabel($network, "network"));
        }
        $nics = json.insert($nics, "/-", $entry);
    }
    def params as map of string to string init {
        "guest_name": $spec.name,
        "storage_name": $spec.storage,
        "vdisks": json.encode($disks),
        "vnics": json.encode($nics)
    };
    def what as string init "SYNO.Virtualization.API.Guest create";
    def done as json.Value init waitVm($c, $what, vmm($c, "Guest", "create", $params, false));
    if (field($done, "/guest_id") == "") {
        fail($what + ": the task ended without a virtual machine (status " +
            shown(field($done, "/status")) + ")");
    }
    if ($spec.vcpus > 0 or $spec.ramMb > 0) {
        resizeGuest($c, $spec.name, $spec.vcpus, $spec.ramMb);
    }
    return guest($c, $spec.name);
}

/**
 * Change a virtual machine's settings.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @param changes {map of string to string} the `set` parameters
 */
func setGuest(c as Client, name as string, changes as map of string to string) {
    def params as map of string to string init $changes;
    $params["guest_name"] = checkLabel($name, "virtual machine");
    vmm($c, "Guest", "set", $params, false);
}

/**
 * Change a virtual machine's CPUs and memory. A running one takes the change
 * at its next boot.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @param vcpus {int} virtual CPUs; 0 to keep them
 * @param ramMb {int} memory in MiB; 0 to keep it
 * @throws {SynologyError} kind `"synology"` when Virtual Machine Manager refuses
 */
export func resizeGuest(c as Client, name as string, vcpus as int, ramMb as int) {
    def changes as map of string to string init {};
    if ($vcpus > 0) {
        $changes["vcpu_num"] = convert.toString($vcpus);
    }
    if ($ramMb > 0) {
        $changes["vram_size"] = convert.toString($ramMb);
    }
    if (len($changes) == 0) {
        return;
    }
    setGuest($c, $name, $changes);
}

/**
 * Rename a virtual machine.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @param newName {string} the new name
 * @throws {SynologyError} kind `"synology"` on a bad name, or when the name is taken
 *   (code 403)
 */
export func renameGuest(c as Client, name as string, newName as string) {
    setGuest($c, $name, {"new_guest_name": checkLabel($newName, "virtual machine")});
}

/**
 * Choose what a virtual machine does when its host boots.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @param mode {string} `off`, `last` (the state it was in) or `on`
 * @throws {SynologyError} kind `"synology"` on another mode, or when Virtual Machine
 *   Manager refuses
 */
export func setAutorun(c as Client, name as string, mode as string) {
    def modes as list of string init ["off", "last", "on"];
    def i as int init lists.indexOf($modes, $mode);
    if ($i < 0) {
        fail("an autorun mode is off, last or on, got " + shown($mode));
    }
    setGuest($c, $name, {"autorun": convert.toString($i)});
}

/**
 * Delete a virtual machine and its virtual disks. There is no undo.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @throws {SynologyError} kind `"synology"` when it is running (code 904), or as
 *   `call`
 */
export func deleteGuest(c as Client, name as string) {
    vmm($c, "Guest", "delete", {"guest_name": checkLabel($name, "virtual machine")}, false);
}

/**
 * Power on a virtual machine. In a cluster, VMM picks the host.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @throws {SynologyError} kind `"synology"` when the host lacks CPU or memory (codes
 *   902, 903), or as `call`
 */
export func powerOnGuest(c as Client, name as string) {
    vmm($c, "Guest.Action", "poweron", {"guest_name": checkLabel($name, "virtual machine")}, false);
}

/**
 * Shut a virtual machine down through its operating system, as the power
 * button does. Returns once VMM has asked; the guest may take a while.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func shutdownGuest(c as Client, name as string) {
    vmm(
        $c,
        "Guest.Action",
        "shutdown",
        {"guest_name": checkLabel($name, "virtual machine")},
        false);
}

/**
 * Cut a virtual machine's power, as pulling the plug does.
 *
 * @param c {Client} the client
 * @param name {string} its name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func powerOffGuest(c as Client, name as string) {
    vmm(
        $c,
        "Guest.Action",
        "poweroff",
        {"guest_name": checkLabel($name, "virtual machine")},
        false);
}

/**
 * The hosts of Virtual Machine Manager: the NAS, or its cluster.
 *
 * @param c {Client} the client
 * @return {list of VmHost} the hosts
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func vmHosts(c as Client) {
    def d as json.Value init vmm($c, "Host", "list", {}, true);
    def out as list of VmHost init [];
    for (def p in items($d, "/hosts")) {
        $out[] = VmHost{
            id: field($d, $p + "/host_id"),
            name: field($d, $p + "/host_name"),
            status: field($d, $p + "/status"),
            freeCpus: number($d, $p + "/free_cpu_core"),
            totalCpus: number($d, $p + "/total_cpu_core"),
            freeRamMb: number($d, $p + "/free_ram_size"),
            totalRamMb: number($d, $p + "/total_ram_size")
        };
    }
    return $out;
}

/**
 * The storages of Virtual Machine Manager.
 *
 * @param c {Client} the client
 * @return {list of VmStorage} the storages
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func vmStorages(c as Client) {
    def d as json.Value init vmm($c, "Storage", "list", {}, true);
    def out as list of VmStorage init [];
    for (def p in items($d, "/storages")) {
        $out[] = VmStorage{
            id: field($d, $p + "/storage_id"),
            name: field($d, $p + "/storage_name"),
            hostId: field($d, $p + "/host_id"),
            hostName: field($d, $p + "/host_name"),
            status: field($d, $p + "/status"),
            sizeMb: number($d, $p + "/size"),
            usedMb: number($d, $p + "/used"),
            volumePath: field($d, $p + "/volume_path")
        };
    }
    return $out;
}

/**
 * The networks of Virtual Machine Manager.
 *
 * @param c {Client} the client
 * @return {list of VmNetwork} the networks
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func vmNetworks(c as Client) {
    def d as json.Value init vmm($c, "Network", "list", {}, true);
    def out as list of VmNetwork init [];
    for (def p in items($d, "/networks")) {
        $out[] = VmNetwork{
            id: field($d, $p + "/network_id"),
            name: field($d, $p + "/network_name")
        };
    }
    return $out;
}

/**
 * The images of Virtual Machine Manager.
 *
 * @param c {Client} the client
 * @return {list of VmImage} the images
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func vmImages(c as Client) {
    def d as json.Value init vmm($c, "Guest.Image", "list", {}, true);
    def out as list of VmImage init [];
    for (def p in items($d, "/images")) {
        def storages as list of string init [];
        for (def q in items($d, $p + "/storages")) {
            $storages[] = field($d, $q + "/storage_name");
        }
        $out[] = VmImage{
            id: field($d, $p + "/image_id"),
            name: field($d, $p + "/image_name"),
            type: field($d, $p + "/type"),
            storages: $storages
        };
    }
    return $out;
}

/**
 * Import a file on the NAS as an image, and wait until it is done.
 *
 * @param c {Client} the client
 * @param name {string} the image's name
 * @param type {string} `disk` (a disk to copy), `vdsm` (Virtual DSM) or `iso`
 * @param file {string} the File Station path of the file, e.g.
 *   `/vm/debian-12.qcow2`
 * @param storages {list of string} the names of the storages to keep it on
 * @return {string} the new image's id
 * @throws {SynologyError} kind `"synology"` on a bad name, type or path, or when
 *   Virtual Machine Manager refuses
 */
export func createImage(
    c as Client,
    name as string,
    type as string,
    file as string,
    storages as list of string) {
    checkLabel($name, "image");
    if (not lists.contains(["disk", "vdsm", "iso"], $type)) {
        fail("an image type is disk, vdsm or iso, got " + shown($type));
    }
    def path as string init checkLabel(checkPath($file), "file");
    if (len($storages) == 0) {
        fail("an image needs a storage");
    }
    for (def s in $storages) {
        checkLabel($s, "storage");
    }
    def params as map of string to string init {
        "image_name": $name,
        "type": $type,
        "ds_file_path": $path,
        "storage_names": json.encode($storages)
    };
    def what as string init "SYNO.Virtualization.API.Guest.Image create";
    def done as json.Value init waitVm($c, $what, vmm($c, "Guest.Image", "create", $params, false));
    def id as string init field($done, "/image_id");
    if ($id == "") {
        fail($what + ": the task ended without an image (status " + shown(field($done, "/status")) +
            ")");
    }
    return $id;
}

/**
 * Delete an image. Virtual machines made from it keep their disks.
 *
 * @param c {Client} the client
 * @param name {string} the image's name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func deleteImage(c as Client, name as string) {
    vmm($c, "Guest.Image", "delete", {"image_name": checkLabel($name, "image")}, false);
}

/**
 * Call a method of a `SYNO.Core` API at the oldest version the host
 * speaks, as the DSM web interface does for these undocumented APIs.
 *
 * @param c {Client} the client
 * @param api {string} the API
 * @param method {string} the method
 * @param params {map of string to string} the parameters
 * @param readOnly {bool} whether the request may be retried
 * @return {json.Value} the reply's `data`
 */
func core(
    c as Client,
    api as string,
    method as string,
    params as map of string to string,
    readOnly as bool) {
    return coreAt($c, $api, -1, $method, $params, $readOnly);
}

/**
 * Call a method of an undocumented API at a given version.
 *
 * @param c {Client} the client
 * @param api {string} the API
 * @param version {int} the version; 0 for the newest the host speaks, -1 for
 *   the oldest
 * @param method {string} the method
 * @param params {map of string to string} the parameters
 * @param readOnly {bool} whether the request may be retried
 * @return {json.Value} the reply's `data`
 */
func coreAt(
    c as Client,
    api as string,
    version as int,
    method as string,
    params as map of string to string,
    readOnly as bool) {
    def spec as ApiInfo init apiInfo($c, $api);
    def v as int init $version;
    if ($v == 0) {
        $v = $spec.maxVersion;
    } elseif ($v < 0) {
        $v = $spec.minVersion;
    }
    if ($v < $spec.minVersion or $v > $spec.maxVersion) {
        fail(
            $api + ": the host speaks versions " + convert.toString($spec.minVersion) + " to " +
                convert.toString($spec.maxVersion) + ", the deck needs " + convert.toString($v));
    }
    def doc as json.Value init send($c, $spec, $v, $method, $params, $readOnly);
    return dataOf($doc, $api, $api + " " + $method);
}

/**
 * An account from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the account's pointer
 * @return {User} the account
 */
func userFrom(d as json.Value, p as string) {
    return User{
        name: field($d, $p + "/name"),
        uid: number($d, $p + "/uid"),
        description: field($d, $p + "/description"),
        email: field($d, $p + "/email"),
        expired: field($d, $p + "/expired")
    };
}

# What `users` and `user` ask DSM to add to each account.
def const USER_FIELDS as list of string init ["description", "email", "expired"];

/**
 * The local accounts.
 *
 * @param c {Client} the client
 * @return {list of User} the accounts, by name
 * @throws {SynologyError} kind `"synology"` when the account may not, or as `call`
 */
export func users(c as Client) {
    def params as map of string to string init {
        "type": "local",
        "offset": "0",
        "limit": "-1",
        "sort_by": "name",
        "sort_direction": "ASC",
        "additional": json.encode(USER_FIELDS)
    };
    def d as json.Value init core($c, "SYNO.Core.User", "list", $params, true);
    def out as list of User init [];
    for (def p in items($d, "/users")) {
        $out[] = userFrom($d, $p);
    }
    return $out;
}

/**
 * One local account.
 *
 * @param c {Client} the client
 * @param name {string} the account name
 * @return {User} the account
 * @throws {SynologyError} kind `"synology"` when there is none, or as `call`
 */
export func user(c as Client, name as string) {
    def params as map of string to string init {
        "type": "local",
        "name": checkLabel($name, "user"),
        "additional": json.encode(USER_FIELDS)
    };
    def d as json.Value init core($c, "SYNO.Core.User", "get", $params, true);
    if (len(items($d, "/users")) == 0) {
        fail("SYNO.Core.User get: no account " + shown($name));
    }
    return userFrom($d, "/users/0");
}

/**
 * Create a local account. It belongs to the `users` group; `addToGroup`
 * adds more.
 *
 * @param c {Client} the client
 * @param name {string} the account name
 * @param password {string} its password, as the password policy allows
 * @param description {string} the description; "" for none
 * @param email {string} the e-mail address; "" for none
 * @return {User} the new account
 * @throws {SynologyError} kind `"synology"` on a bad name or an empty password, or
 *   when DSM refuses
 */
export func createUser(
    c as Client,
    name as string,
    password as string,
    description as string,
    email as string) {
    checkLabel($name, "user");
    if ($password == "") {
        fail("an account needs a password");
    }
    def params as map of string to string init {"name": $name, "password": $password};
    if ($description != "") {
        $params["description"] = $description;
    }
    if ($email != "") {
        $params["email"] = $email;
    }
    def d as json.Value init core($c, "SYNO.Core.User", "create", $params, false);
    return User{
        name: $name,
        uid: number($d, "/uid"),
        description: $description,
        email: $email,
        expired: "normal"
    };
}

/**
 * Change an account's settings.
 *
 * @param c {Client} the client
 * @param name {string} the account name
 * @param changes {map of string to string} the `set` parameters
 */
func setUser(c as Client, name as string, changes as map of string to string) {
    def params as map of string to string init $changes;
    $params["name"] = checkLabel($name, "user");
    $params["new_name"] = $name;
    core($c, "SYNO.Core.User", "set", $params, false);
}

/**
 * Set an account's password.
 *
 * @param c {Client} the client
 * @param name {string} the account name
 * @param password {string} the new password
 * @throws {SynologyError} kind `"synology"` on an empty password, or when DSM refuses
 */
export func setUserPassword(c as Client, name as string, password as string) {
    if ($password == "") {
        fail("an account needs a password");
    }
    setUser($c, $name, {"password": $password});
}

/**
 * Enable or disable an account. A disabled account cannot log in; its files
 * and settings stay.
 *
 * @param c {Client} the client
 * @param name {string} the account name
 * @param enabled {bool} whether it may log in
 * @throws {SynologyError} kind `"synology"` when DSM refuses
 */
export func setUserEnabled(c as Client, name as string, enabled as bool) {
    def expired as string init "now";
    if ($enabled) {
        $expired = "normal";
    }
    setUser($c, $name, {"expired": $expired});
}

/**
 * Delete a local account. Its home folder stays unless DSM is set to remove
 * it.
 *
 * @param c {Client} the client
 * @param name {string} the account name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func deleteUser(c as Client, name as string) {
    core($c, "SYNO.Core.User", "delete", {"name": checkLabel($name, "user")}, false);
}

/**
 * The local groups.
 *
 * @param c {Client} the client
 * @return {list of Group} the groups
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func groups(c as Client) {
    def params as map of string to string init {
        "type": "local",
        "offset": "0",
        "limit": "-1",
        "name_only": "false"
    };
    def d as json.Value init core($c, "SYNO.Core.Group", "list", $params, true);
    def out as list of Group init [];
    for (def p in items($d, "/groups")) {
        $out[] = Group{
            name: field($d, $p + "/name"),
            gid: number($d, $p + "/gid"),
            description: field($d, $p + "/description")
        };
    }
    return $out;
}

/**
 * The members of a local group.
 *
 * @param c {Client} the client
 * @param group {string} the group
 * @return {list of string} the account names
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func groupMembers(c as Client, group as string) {
    def params as map of string to string init {
        "group": checkLabel($group, "group"),
        "ingroup": "true"
    };
    def d as json.Value init core($c, "SYNO.Core.Group.Member", "list", $params, true);
    def out as list of string init [];
    for (def p in items($d, "/users")) {
        $out[] = field($d, $p + "/name");
    }
    return $out;
}

/**
 * Change a group's members.
 *
 * @param c {Client} the client
 * @param group {string} the group
 * @param add {list of string} accounts to add
 * @param remove {list of string} accounts to remove
 */
func changeMembers(c as Client, group as string, add as list of string, remove as list of string) {
    for (def name in $add) {
        checkLabel($name, "user");
    }
    for (def name in $remove) {
        checkLabel($name, "user");
    }
    def params as map of string to string init {
        "group": checkLabel($group, "group"),
        "add_member": json.encode($add),
        "remove_member": json.encode($remove)
    };
    core($c, "SYNO.Core.Group.Member", "change", $params, false);
}

/**
 * Add accounts to a local group.
 *
 * @param c {Client} the client
 * @param group {string} the group, e.g. `administrators`
 * @param names {list of string} the accounts
 * @throws {SynologyError} kind `"synology"` on a bad name, or when DSM refuses
 */
export func addToGroup(c as Client, group as string, names as list of string) {
    changeMembers($c, $group, $names, []);
}

/**
 * Remove accounts from a local group.
 *
 * @param c {Client} the client
 * @param group {string} the group
 * @param names {list of string} the accounts
 * @throws {SynologyError} kind `"synology"` on a bad name, or when DSM refuses
 */
export func removeFromGroup(c as Client, group as string, names as list of string) {
    changeMembers($c, $group, [], $names);
}

/**
 * Create a shared folder with its recycle bin on, for administrators only.
 *
 * @param c {Client} the client
 * @param name {string} the share name, e.g. `backup`
 * @param volume {string} the volume, e.g. `/volume1`
 * @param description {string} the description; "" for none
 * @return {string} the share's File Station path, e.g. `/backup`
 * @throws {SynologyError} kind `"synology"` on a bad name or volume, or when DSM
 *   refuses
 */
export func createShare(c as Client, name as string, volume as string, description as string) {
    checkLabel($name, "share");
    if (strings.contains($name, "/") or not regex.matches("^/[A-Za-z0-9_]+$", $volume)) {
        fail("a share is a name on a volume such as /volume1, got " + shown($name) + " on " +
            shown($volume));
    }
    def settings as json.Value init json.decode('{"enable_recycle_bin":true}');
    $settings = json.set($settings, "/recycle_bin_admin_only", true);
    $settings = json.set($settings, "/name", $name);
    $settings = json.set($settings, "/vol_path", $volume);
    $settings = json.set($settings, "/desc", $description);
    def spec as ApiInfo init apiInfo($c, "SYNO.Core.Share");
    def params as map of string to string init {"name": $name, "shareinfo": json.encode($settings)};
    def what as string init "SYNO.Core.Share create";
    dataOf(send($c, $spec, $spec.maxVersion, "create", $params, false), "SYNO.Core.Share", $what);
    return "/" + $name;
}

/**
 * Delete a shared folder with everything in it. There is no undo.
 *
 * @param c {Client} the client
 * @param name {string} the share name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func deleteShare(c as Client, name as string) {
    core($c, "SYNO.Core.Share", "delete", {"name": checkLabel($name, "share")}, false);
}

/**
 * The `user_group_type` of a permission list.
 *
 * @param kind {string} `user` or `group`
 * @return {string} `local_user` or `local_group`
 */
func principalType(kind as string) {
    if ($kind == "user") {
        return "local_user";
    }
    if ($kind == "group") {
        return "local_group";
    }
    fail("a permission is for a user or a group, got " + shown($kind));
    return "";
}

/**
 * Who may do what in a shared folder.
 *
 * @param c {Client} the client
 * @param share {string} the share name
 * @param kind {string} `user` for local users, `group` for local groups
 * @return {list of SharePermission} every user or group, with its access
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func sharePermissions(c as Client, share as string, kind as string) {
    def out as list of SharePermission init [];
    def offset as int init 0;
    def more as bool init true;
    while ($more) {
        def params as map of string to string init {
            "name": checkLabel($share, "share"),
            "user_group_type": principalType($kind),
            "action": "enum",
            "offset": convert.toString($offset),
            "limit": convert.toString(PAGE_SIZE)
        };
        def d as json.Value init core($c, "SYNO.Core.Share.Permission", "list", $params, true);
        def page as list of string init items($d, "/items");
        for (def p in $page) {
            def access as string init "none";
            if (flag($d, $p + "/is_deny")) {
                $access = "deny";
            } elseif (flag($d, $p + "/is_writable")) {
                $access = "rw";
            } elseif (flag($d, $p + "/is_readonly")) {
                $access = "ro";
            }
            $out[] = SharePermission{
                name: field($d, $p + "/name"),
                access: $access,
                isAdmin: flag($d, $p + "/is_admin")
            };
        }
        $offset = $offset + len($page);
        $more = len($page) > 0 and $offset < number($d, "/total");
    }
    return $out;
}

/**
 * Set what one user or group may do in a shared folder.
 *
 * @param c {Client} the client
 * @param share {string} the share name
 * @param kind {string} `user` or `group`
 * @param name {string} the user or group
 * @param access {string} `rw`, `ro`, `deny` or `none`
 * @throws {SynologyError} kind `"synology"` on another access, or when DSM refuses
 */
export func setSharePermission(
    c as Client,
    share as string,
    kind as string,
    name as string,
    access as string) {
    if (not lists.contains(["rw", "ro", "deny", "none"], $access)) {
        fail("an access is rw, ro, deny or none, got " + shown($access));
    }
    def entry as json.Value init json.decode('{"is_custom":false}');
    $entry = json.set($entry, "/name", checkLabel($name, $kind));
    $entry = json.set($entry, "/is_writable", $access == "rw");
    $entry = json.set($entry, "/is_readonly", $access == "ro");
    $entry = json.set($entry, "/is_deny", $access == "deny");
    def entries as json.Value init json.insert(json.decode("[]"), "/-", $entry);
    def params as map of string to string init {
        "name": checkLabel($share, "share"),
        "user_group_type": principalType($kind),
        "permissions": json.encode($entries)
    };
    core($c, "SYNO.Core.Share.Permission", "set", $params, false);
}

/**
 * A certificate from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the certificate's pointer
 * @return {Certificate} the certificate
 */
func certificateFrom(d as json.Value, p as string) {
    def services as list of string init [];
    for (def q in items($d, $p + "/services")) {
        $services[] = field($d, $q + "/display_name");
    }
    return Certificate{
        id: field($d, $p + "/id"),
        description: field($d, $p + "/desc"),
        isDefault: flag($d, $p + "/is_default"),
        commonName: field($d, $p + "/subject/common_name"),
        issuer: field($d, $p + "/issuer/common_name"),
        validFrom: field($d, $p + "/valid_from"),
        validTill: field($d, $p + "/valid_till"),
        services: $services
    };
}

/**
 * The certificates of DSM, with the services using each.
 *
 * @param c {Client} the client
 * @return {list of Certificate} the certificates
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func certificates(c as Client) {
    def d as json.Value init coreAt($c, "SYNO.Core.Certificate.CRT", 1, "list", {}, true);
    def out as list of Certificate init [];
    for (def p in items($d, "/certificates")) {
        $out[] = certificateFrom($d, $p);
    }
    return $out;
}

/**
 * Import a certificate with its private key, or renew one in place.
 *
 * @param c {Client} the client
 * @param key {bytes} the private key, PEM
 * @param cert {bytes} the certificate, PEM
 * @param chain {bytes} the intermediate certificates, PEM; empty for none
 * @param description {string} the description; "" for none
 * @param replaceId {string} the id of a certificate to replace, keeping its
 *   services; "" for a new one
 * @param asDefault {bool} make it the default certificate
 * @return {string} the certificate's id
 * @throws {SynologyError} kind `"synology"` when the key or certificate is missing,
 *   or when DSM refuses them
 * @example
 *   def key as bytes init fs.readBytes("privkey.pem");
 *   def pem as bytes init fs.readBytes("cert.pem");
 *   synology.importCertificate($c, $key, $pem, fs.readBytes("chain.pem"), "", $old.id, false);
 */
export func importCertificate(
    c as Client,
    key as bytes,
    cert as bytes,
    chain as bytes,
    description as string,
    replaceId as string,
    asDefault as bool) {
    if (len($key) == 0 or len($cert) == 0) {
        fail("a certificate needs its key and certificate");
    }
    def spec as ApiInfo init apiInfo($c, "SYNO.Core.Certificate");
    def asText as string init "";
    if ($asDefault) {
        $asText = "true";
    }
    def parts as list of multipart.Part init [
        multipart.field("id", $replaceId),
        multipart.field("desc", $description),
        multipart.field("as_default", $asText),
        multipart.file("key", "key.pem", "application/x-x509-ca-cert", $key),
        multipart.file("cert", "cert.pem", "application/x-x509-ca-cert", $cert)
    ];
    if (len($chain) > 0) {
        $parts[] = multipart.file("inter_cert", "chain.pem", "application/x-x509-ca-cert", $chain);
    }
    def d as json.Value init postParts($c, $spec, $spec.minVersion, "import", $parts);
    def id as string init field($d, "/id");
    if ($id == "") {
        $id = $replaceId;
    }
    return $id;
}

/**
 * Make a certificate the default one.
 *
 * @param c {Client} the client
 * @param id {string} the certificate's id
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func setDefaultCertificate(c as Client, id as string) {
    def params as map of string to string init {
        "id": json.encode(checkLabel($id, "certificate")),
        "desc": '""',
        "as_default": "true"
    };
    coreAt($c, "SYNO.Core.Certificate.CRT", 1, "set", $params, false);
}

/**
 * Delete a certificate.
 *
 * @param c {Client} the client
 * @param id {string} the certificate's id
 * @throws {SynologyError} kind `"synology"` when a service still uses it, or as `call`
 */
export func deleteCertificate(c as Client, id as string) {
    def params as map of string to string init {
        "ids": json.encode([checkLabel($id, "certificate")])
    };
    coreAt($c, "SYNO.Core.Certificate.CRT", 1, "delete", $params, false);
}

/**
 * Let a service use a certificate.
 *
 * @param c {Client} the client
 * @param id {string} the certificate's id
 * @param service {string} the service's name as DSM shows it, e.g.
 *   `DSM Desktop Service` or `FTPS`
 * @throws {SynologyError} kind `"synology"` when no certificate lists the service,
 *   or as `call`
 */
export func assignCertificate(c as Client, id as string, service as string) {
    checkLabel($id, "certificate");
    def d as json.Value init coreAt($c, "SYNO.Core.Certificate.CRT", 1, "list", {}, true);
    def oldId as string init "";
    def found as json.Value init json.decode("null");
    for (def p in items($d, "/certificates")) {
        for (def q in items($d, $p + "/services")) {
            if (field($d, $q + "/display_name") == $service and json.isNull($found)) {
                $found = json.get($d, $q);
                $oldId = field($d, $p + "/id");
            }
        }
    }
    if (json.isNull($found)) {
        fail("SYNO.Core.Certificate.Service: no certificate serves " + shown($service));
    }
    if ($oldId == $id) {
        return;
    }
    def setting as json.Value init json.set(json.decode('{}'), "/service", $found);
    $setting = json.set($setting, "/old_id", $oldId);
    $setting = json.set($setting, "/id", $id);
    def settings as json.Value init json.insert(json.decode("[]"), "/-", $setting);
    coreAt(
        $c,
        "SYNO.Core.Certificate.Service",
        -1,
        "set",
        {"settings": json.encode($settings)},
        false);
}

/**
 * The snapshots of a shared folder.
 *
 * @param c {Client} the client
 * @param share {string} the share name
 * @return {list of Snapshot} the snapshots
 * @throws {SynologyError} kind `"synology"` when the share is not on Btrfs, or as
 *   `call`
 */
export func snapshots(c as Client, share as string) {
    def params as map of string to string init {
        "name": checkLabel($share, "share"),
        "filter": '{"attr":[]}',
        "additional": "[]",
        "offset": "0",
        "limit": "-1"
    };
    def d as json.Value init coreAt($c, "SYNO.Core.Share.Snapshot", 2, "list", $params, true);
    def out as list of Snapshot init [];
    for (def p in items($d, "/snapshots")) {
        $out[] = Snapshot{
            name: field($d, $p + "/time"),
            description: field($d, $p + "/desc"),
            locked: flag($d, $p + "/lock"),
            scheduled: flag($d, $p + "/schedule_snapshot")
        };
    }
    return $out;
}

/**
 * Take a snapshot of a shared folder on Btrfs.
 *
 * @param c {Client} the client
 * @param share {string} the share name
 * @param description {string} the description; "" for none
 * @param lock {bool} keep it from automatic removal
 * @return {string} the snapshot's name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func createSnapshot(c as Client, share as string, description as string, lock as bool) {
    def snapinfo as json.Value init json.set(json.decode('{}'), "/desc", $description);
    $snapinfo = json.set($snapinfo, "/lock", $lock);
    def params as map of string to string init {
        "name": checkLabel($share, "share"),
        "snapinfo": json.encode($snapinfo)
    };
    def d as json.Value init coreAt($c, "SYNO.Core.Share.Snapshot", 1, "create", $params, false);
    return field($d, "");
}

/**
 * Delete a snapshot.
 *
 * @param c {Client} the client
 * @param share {string} the share name
 * @param name {string} the snapshot's name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func deleteSnapshot(c as Client, share as string, name as string) {
    def params as map of string to string init {
        "name": checkLabel($share, "share"),
        "snapshots": json.encode([checkLabel($name, "snapshot")])
    };
    coreAt($c, "SYNO.Core.Share.Snapshot", 1, "delete", $params, false);
}

/**
 * How busy the NAS is: CPU, memory and network.
 *
 * @param c {Client} the client
 * @return {Utilization} the figures
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func utilization(c as Client) {
    def d as json.Value init coreAt($c, "SYNO.Core.System.Utilization", 0, "get", {}, true);
    def u as Utilization init Utilization{
        cpuPercent: number($d, "/cpu/user_load") + number($d, "/cpu/system_load") +
            number($d, "/cpu/other_load"),
        memoryPercent: number($d, "/memory/real_usage"),
        memoryTotalKb: number($d, "/memory/total_real"),
        memoryAvailableKb: number($d, "/memory/avail_real"),
        rxBytes: 0,
        txBytes: 0
    };
    for (def p in items($d, "/network")) {
        if (field($d, $p + "/device") == "total") {
            $u.rxBytes = number($d, $p + "/rx");
            $u.txBytes = number($d, $p + "/tx");
        }
    }
    return $u;
}

/**
 * The storage manager's view of volumes and drives.
 *
 * @param c {Client} the client
 * @return {json.Value} the reply's `data`
 */
func storageInfo(c as Client) {
    return coreAt($c, "SYNO.Storage.CGI.Storage", 0, "load_info", {}, true);
}

/**
 * The storage volumes and their state.
 *
 * @param c {Client} the client
 * @return {list of Volume} the volumes
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func volumes(c as Client) {
    def d as json.Value init storageInfo($c);
    def out as list of Volume init [];
    for (def p in items($d, "/volumes")) {
        $out[] = Volume{
            id: field($d, $p + "/id"),
            path: field($d, $p + "/vol_path"),
            status: field($d, $p + "/status"),
            fsType: field($d, $p + "/fs_type"),
            totalBytes: number($d, $p + "/size/total"),
            usedBytes: number($d, $p + "/size/used")
        };
    }
    return $out;
}

/**
 * The drives, with their health and temperature.
 *
 * @param c {Client} the client
 * @return {list of Disk} the drives
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func disks(c as Client) {
    def d as json.Value init storageInfo($c);
    def out as list of Disk init [];
    for (def p in items($d, "/disks")) {
        $out[] = Disk{
            id: field($d, $p + "/id"),
            name: field($d, $p + "/name"),
            model: strings.trim(field($d, $p + "/model")),
            status: field($d, $p + "/status"),
            smartStatus: field($d, $p + "/smart_status"),
            temperature: number($d, $p + "/temp"),
            sizeBytes: number($d, $p + "/size_total")
        };
    }
    return $out;
}

/**
 * Restart the NAS. The session ends with it.
 *
 * @param c {Client} the client
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func reboot(c as Client) {
    coreAt($c, "SYNO.Core.System", 0, "reboot", {}, false);
}

/**
 * Turn the NAS off.
 *
 * @param c {Client} the client
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func shutdown(c as Client) {
    coreAt($c, "SYNO.Core.System", 0, "shutdown", {}, false);
}

/**
 * Ask Synology's update server whether a DSM update is available.
 *
 * @param c {Client} the client
 * @return {DsmUpdate} what is on offer
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func checkUpdate(c as Client) {
    def d as json.Value init coreAt($c, "SYNO.Core.Upgrade.Server", 0, "check", {}, true);
    return DsmUpdate{
        available: flag($d, "/update/available"),
        version: field($d, "/update/version"),
        reboot: field($d, "/update/reboot")
    };
}

/**
 * The installed packages.
 *
 * @param c {Client} the client
 * @return {list of Package} the packages
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func packages(c as Client) {
    def params as map of string to string init {"additional": '["status"]'};
    def d as json.Value init coreAt($c, "SYNO.Core.Package", 0, "list", $params, true);
    def out as list of Package init [];
    for (def p in items($d, "/packages")) {
        $out[] = Package{
            id: field($d, $p + "/id"),
            name: field($d, $p + "/name"),
            version: field($d, $p + "/version"),
            status: field($d, $p + "/additional/status")
        };
    }
    return $out;
}

/**
 * Start or stop a package.
 *
 * @param c {Client} the client
 * @param id {string} the package id
 * @param action {string} `start` or `stop`
 */
func controlPackage(c as Client, id as string, action as string) {
    if (not regex.matches("^[A-Za-z0-9_.-]+$", $id)) {
        fail("a package id is letters, digits, _, . and -, got " + shown($id));
    }
    coreAt($c, "SYNO.Core.Package.Control", 0, $action, {"id": $id}, false);
}

/**
 * Start a package.
 *
 * @param c {Client} the client
 * @param id {string} the package id, e.g. `ContainerManager`
 * @throws {SynologyError} kind `"synology"` on a bad id, or as `call`
 */
export func startPackage(c as Client, id as string) {
    controlPackage($c, $id, "start");
}

/**
 * Stop a package.
 *
 * @param c {Client} the client
 * @param id {string} the package id
 * @throws {SynologyError} kind `"synology"` on a bad id, or as `call`
 */
export func stopPackage(c as Client, id as string) {
    controlPackage($c, $id, "stop");
}

# The services `serviceEnabled` and `setService` know: API and flag.
def const SERVICES as map of string to list of string init {
    "ssh": ["SYNO.Core.Terminal", "enable_ssh"],
    "smb": ["SYNO.Core.FileServ.SMB", "enable_samba"],
    "nfs": ["SYNO.Core.FileServ.NFS", "enable_nfs"]
};

/**
 * The API and flag of a service.
 *
 * @param service {string} `ssh`, `smb` or `nfs`
 * @return {list of string} the API and the flag
 */
func serviceOf(service as string) {
    if (not maps.has(SERVICES, $service)) {
        fail("a service is ssh, smb or nfs, got " + shown($service));
    }
    return SERVICES[$service];
}

/**
 * Whether a file or terminal service is on.
 *
 * @param c {Client} the client
 * @param service {string} `ssh`, `smb` or `nfs`
 * @return {bool} whether it is on
 * @throws {SynologyError} kind `"synology"` on another service, or as `call`
 */
export func serviceEnabled(c as Client, service as string) {
    def which as list of string init serviceOf($service);
    return flag(coreAt($c, $which[0], 0, "get", {}, true), "/" + $which[1]);
}

/**
 * Turn a file or terminal service on or off.
 *
 * @param c {Client} the client
 * @param service {string} `ssh`, `smb` or `nfs`
 * @param enabled {bool} whether it is on
 * @throws {SynologyError} kind `"synology"` on another service, or as `call`
 */
export func setService(c as Client, service as string, enabled as bool) {
    def which as list of string init serviceOf($service);
    coreAt($c, $which[0], 0, "set", {$which[1]: convert.toString($enabled)}, false);
}

/**
 * The tasks of the Task Scheduler.
 *
 * @param c {Client} the client
 * @return {list of ScheduledTask} the tasks
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func scheduledTasks(c as Client) {
    def out as list of ScheduledTask init [];
    def offset as int init 0;
    def more as bool init true;
    while ($more) {
        def params as map of string to string init {
            "sort_by": "name",
            "sort_direction": "ASC",
            "offset": convert.toString($offset),
            "limit": convert.toString(PAGE_SIZE)
        };
        def d as json.Value init coreAt($c, "SYNO.Core.TaskScheduler", 3, "list", $params, true);
        def page as list of string init items($d, "/tasks");
        for (def p in $page) {
            $out[] = ScheduledTask{
                id: number($d, $p + "/id"),
                name: field($d, $p + "/name"),
                owner: field($d, $p + "/real_owner"),
                type: field($d, $p + "/type"),
                enabled: flag($d, $p + "/enable"),
                nextRun: field($d, $p + "/next_trigger_time"),
                action: field($d, $p + "/action")
            };
        }
        $offset = $offset + len($page);
        $more = len($page) > 0 and $offset < number($d, "/total");
    }
    return $out;
}

/**
 * The `[{"id": ..., "real_owner": ...}]` a task method takes.
 *
 * @param job {ScheduledTask} the task
 * @param extra {map of string to bool} more members
 * @return {string} the JSON
 */
func taskList(job as ScheduledTask, extra as map of string to bool) {
    def entry as json.Value init json.set(json.decode('{}'), "/id", $job.id);
    $entry = json.set($entry, "/real_owner", $job.owner);
    for (def key in maps.keys($extra)) {
        $entry = json.set($entry, "/" + $key, $extra[$key]);
    }
    return json.encode(json.insert(json.decode("[]"), "/-", $entry));
}

/**
 * Run a scheduled task now.
 *
 * @param c {Client} the client
 * @param job {ScheduledTask} the task, from `scheduledTasks`
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func runScheduledTask(c as Client, job as ScheduledTask) {
    coreAt($c, "SYNO.Core.TaskScheduler", 2, "run", {"tasks": taskList($job, {})}, false);
}

/**
 * Turn a scheduled task's schedule on or off.
 *
 * @param c {Client} the client
 * @param job {ScheduledTask} the task, from `scheduledTasks`
 * @param enabled {bool} whether it runs on its schedule
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func setScheduledTaskEnabled(c as Client, job as ScheduledTask, enabled as bool) {
    def params as map of string to string init {"status": taskList($job, {"enable": $enabled})};
    coreAt($c, "SYNO.Core.TaskScheduler", 2, "set_enable", $params, false);
}

/**
 * The recent runs of a scheduled task, newest first.
 *
 * @param c {Client} the client
 * @param job {ScheduledTask} the task
 * @return {list of TaskResult} the runs
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func taskResults(c as Client, job as ScheduledTask) {
    def params as map of string to string init {"id": convert.toString($job.id)};
    def d as json.Value init coreAt(
        $c,
        "SYNO.Core.TaskScheduler",
        1,
        "get_history_status_list",
        $params,
        true);
    def out as list of TaskResult init [];
    for (def p in items($d, "")) {
        $out[] = TaskResult{
            start: field($d, $p + "/start_time"),
            stop: field($d, $p + "/stop_time"),
            exitCode: number($d, $p + "/exit_code"),
            exitType: field($d, $p + "/exit_type")
        };
    }
    return $out;
}

/**
 * A Hyper Backup task from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the task's pointer; "" for the root
 * @return {BackupTask} the task
 */
func backupFrom(d as json.Value, p as string) {
    return BackupTask{
        id: number($d, $p + "/task_id"),
        name: field($d, $p + "/name"),
        state: field($d, $p + "/state"),
        status: field($d, $p + "/status"),
        lastResult: field($d, $p + "/last_bkp_result"),
        lastTime: field($d, $p + "/last_bkp_time"),
        nextTime: field($d, $p + "/next_bkp_time")
    };
}

/**
 * The Hyper Backup tasks.
 *
 * @param c {Client} the client
 * @return {list of BackupTask} the tasks; `lastResult` and the times come
 *   with `backupStatus`
 * @throws {SynologyError} kind `"synology"` when Hyper Backup is not installed, or as
 *   `call`
 */
export func backupTasks(c as Client) {
    def d as json.Value init coreAt($c, "SYNO.Backup.Task", -1, "list", {}, true);
    def out as list of BackupTask init [];
    for (def p in items($d, "/task_list")) {
        $out[] = backupFrom($d, $p);
    }
    return $out;
}

# What `backupStatus` asks Hyper Backup to add.
def const BACKUP_FIELDS as list of string init [
    "last_bkp_time",
    "next_bkp_time",
    "last_bkp_result",
    "is_modified",
    "last_bkp_progress"
];

/**
 * The state of a Hyper Backup task and its last run.
 *
 * @param c {Client} the client
 * @param id {int} the task id
 * @return {BackupTask} the task
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func backupStatus(c as Client, id as int) {
    def params as map of string to string init {
        "task_id": convert.toString($id),
        "blOnline": "false",
        "additional": json.encode(BACKUP_FIELDS)
    };
    def d as json.Value init coreAt($c, "SYNO.Backup.Task", -1, "status", $params, true);
    def job as BackupTask init backupFrom($d, "");
    $job.id = $id;
    return $job;
}

/**
 * Start a Hyper Backup task now.
 *
 * @param c {Client} the client
 * @param id {int} the task id
 * @throws {SynologyError} kind `"synology"` when it is not in a state to back up, or
 *   as `call`
 */
export func runBackup(c as Client, id as int) {
    coreAt($c, "SYNO.Backup.Task", -1, "backup", {"task_id": convert.toString($id)}, false);
}

/**
 * Refuse a container name Docker would not take.
 *
 * @param name {string} the name
 * @return {string} the name
 */
func checkContainer(name as string) {
    if (not regex.matches("^[A-Za-z0-9][A-Za-z0-9_.-]*$", $name)) {
        fail("a container name is letters, digits, _, . and -, got " + shown($name));
    }
    return $name;
}

/**
 * The containers, running or not.
 *
 * @param c {Client} the client
 * @return {list of Container} the containers
 * @throws {SynologyError} kind `"synology"` when Container Manager is not installed,
 *   or as `call`
 */
export func containers(c as Client) {
    def params as map of string to string init {"limit": "-1", "offset": "0", "type": "all"};
    def d as json.Value init coreAt($c, "SYNO.Docker.Container", 0, "list", $params, true);
    def out as list of Container init [];
    for (def p in items($d, "/containers")) {
        $out[] = Container{
            name: field($d, $p + "/name"),
            id: field($d, $p + "/id"),
            image: field($d, $p + "/image"),
            status: field($d, $p + "/status")
        };
    }
    return $out;
}

/**
 * Everything Docker knows about a container (its inspect data: `Config`,
 * `HostConfig`, `State`, ...).
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @return {json.Value} the data
 * @throws {SynologyError} kind `"synology"` when there is none, or as `call`
 */
export func inspectContainer(c as Client, name as string) {
    return coreAt($c, "SYNO.Docker.Container", 0, "get", {"name": checkContainer($name)}, true);
}

/**
 * Start, stop or restart a container.
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @param action {string} the method
 */
func controlContainer(c as Client, name as string, action as string) {
    coreAt($c, "SYNO.Docker.Container", 0, $action, {"name": checkContainer($name)}, false);
}

/**
 * Start a container.
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @throws {SynologyError} kind `"synology"` on a bad name, or as `call`
 */
export func startContainer(c as Client, name as string) {
    controlContainer($c, $name, "start");
}

/**
 * Stop a container.
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @throws {SynologyError} kind `"synology"` on a bad name, or as `call`
 */
export func stopContainer(c as Client, name as string) {
    controlContainer($c, $name, "stop");
}

/**
 * Restart a container.
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @throws {SynologyError} kind `"synology"` on a bad name, or as `call`
 */
export func restartContainer(c as Client, name as string) {
    controlContainer($c, $name, "restart");
}

/**
 * Delete a container. Its image stays.
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @param force {bool} delete it even while it runs
 * @throws {SynologyError} kind `"synology"` when it runs and `force` is false, or as
 *   `call`
 */
export func deleteContainer(c as Client, name as string, force as bool) {
    def params as map of string to string init {
        "name": checkContainer($name),
        "force": convert.toString($force)
    };
    coreAt($c, "SYNO.Docker.Container", 0, "delete", $params, false);
}

/**
 * The newest lines a container wrote, newest first.
 *
 * @param c {Client} the client
 * @param name {string} the container name
 * @param limit {int} how many lines, at least 1
 * @return {list of LogLine} the lines
 * @throws {SynologyError} kind `"synology"` on a bad name or limit, or as `call`
 */
export func containerLogs(c as Client, name as string, limit as int) {
    if ($limit < 1) {
        fail("a log read asks for at least one line");
    }
    def params as map of string to string init {
        "name": checkContainer($name),
        "sort_dir": "DESC",
        "offset": "0",
        "limit": convert.toString($limit)
    };
    def d as json.Value init coreAt($c, "SYNO.Docker.Container.Log", 0, "get", $params, true);
    def out as list of LogLine init [];
    for (def p in items($d, "/logs")) {
        $out[] = LogLine{
            created: field($d, $p + "/created"),
            stream: field($d, $p + "/stream"),
            text: field($d, $p + "/text")
        };
    }
    return $out;
}

/**
 * Refuse an image repository or tag.
 *
 * @param repository {string} e.g. `caddy` or `ghcr.io/owner/app`
 * @param tag {string} e.g. `latest`
 */
func checkImage(repository as string, tag as string) {
    if (not regex.matches("^[a-z0-9][a-z0-9._/:-]*$", $repository) or
        strings.contains($repository, "..")) {
        fail("an image repository is lowercase letters, digits, ., _, /, : and -, got " +
            shown($repository));
    }
    if (not regex.matches("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", $tag)) {
        fail("an image tag is letters, digits, _, . and -, got " + shown($tag));
    }
}

/**
 * The container images on the NAS.
 *
 * @param c {Client} the client
 * @return {list of ContainerImage} the images
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func containerImages(c as Client) {
    def params as map of string to string init {"limit": "-1", "offset": "0", "show_dsm": "false"};
    def d as json.Value init coreAt($c, "SYNO.Docker.Image", 0, "list", $params, true);
    def out as list of ContainerImage init [];
    for (def p in items($d, "/images")) {
        def tags as list of string init [];
        for (def q in items($d, $p + "/tags")) {
            $tags[] = field($d, $q);
        }
        $out[] = ContainerImage{
            id: field($d, $p + "/id"),
            repository: field($d, $p + "/repository"),
            tags: $tags,
            size: number($d, $p + "/size"),
            created: number($d, $p + "/created"),
            upgradable: flag($d, $p + "/upgradable")
        };
    }
    return $out;
}

/**
 * Pull an image from the registry Container Manager uses (Docker Hub
 * unless set otherwise).
 *
 * @param c {Client} the client
 * @param repository {string} e.g. `caddy`
 * @param tag {string} e.g. `alpine`
 * @throws {SynologyError} kind `"synology"` on a bad name, or as `call`
 */
export func pullContainerImage(c as Client, repository as string, tag as string) {
    checkImage($repository, $tag);
    def params as map of string to string init {"repository": $repository, "tag": $tag};
    coreAt($c, "SYNO.Docker.Image", 0, "pull", $params, false);
}

/**
 * Delete an image.
 *
 * @param c {Client} the client
 * @param repository {string} e.g. `caddy`
 * @param tag {string} e.g. `alpine`
 * @throws {SynologyError} kind `"synology"` when a container uses it, or as `call`
 */
export func deleteContainerImage(c as Client, repository as string, tag as string) {
    checkImage($repository, $tag);
    def params as map of string to string init {"name": $repository, "tag": $tag};
    coreAt($c, "SYNO.Docker.Image", 0, "delete", $params, false);
}

/**
 * A project from a reply.
 *
 * @param d {json.Value} the reply
 * @param p {string} the project's pointer; "" for the root
 * @return {Project} the project
 */
func projectFrom(d as json.Value, p as string) {
    def ids as list of string init [];
    for (def q in items($d, $p + "/containerIds")) {
        $ids[] = field($d, $q);
    }
    return Project{
        id: field($d, $p + "/id"),
        name: field($d, $p + "/name"),
        path: field($d, $p + "/share_path"),
        status: field($d, $p + "/status"),
        containerIds: $ids
    };
}

/**
 * Refuse a project id.
 *
 * @param id {string} the id
 * @return {string} the id
 */
func checkProject(id as string) {
    if (not regex.matches("^[0-9A-Fa-f-]+$", $id)) {
        fail("a project id is a UUID, got " + shown($id));
    }
    return $id;
}

/**
 * The Compose projects.
 *
 * @param c {Client} the client
 * @return {list of Project} the projects, by name
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func projects(c as Client) {
    def d as json.Value init coreAt($c, "SYNO.Docker.Project", 0, "list", {}, true);
    def out as list of Project init [];
    if (kindAt($d, "") != "map") {
        return $out;
    }
    # The reply is keyed by id; sort by name, the id breaking ties.
    def byName as map of string to Project init {};
    for (def key in json.keys($d)) {
        def one as Project init projectFrom($d, "/" + pointerToken($key));
        $byName[$one.name + " " + $one.id] = $one;
    }
    for (def key in lists.sort(maps.keys($byName))) {
        $out[] = $byName[$key];
    }
    return $out;
}

/**
 * One Compose project.
 *
 * @param c {Client} the client
 * @param id {string} the project id
 * @return {Project} the project
 * @throws {SynologyError} kind `"synology"` when there is none, or as `call`
 */
export func project(c as Client, id as string) {
    def d as json.Value init coreAt(
        $c,
        "SYNO.Docker.Project",
        0,
        "get",
        {"id": checkProject($id)},
        true);
    return projectFrom($d, "");
}

/**
 * Create a Compose project from a `compose.yaml`. Container Manager writes
 * the file into the project's folder; `buildProject` then pulls and starts
 * it.
 *
 * @param c {Client} the client
 * @param name {string} the project name: lowercase letters, digits, `_` and `-`
 * @param folder {string} its folder, an existing File Station path such as
 *   `/docker/app`
 * @param compose {string} the content of `compose.yaml`
 * @return {string} the project id
 * @throws {SynologyError} kind `"synology"` on a bad name or path, an empty file, or
 *   when Container Manager refuses
 * @example
 *   def yaml as string init fs.readString("compose.yaml");
 *   def id as string init synology.createProject($c, "web", "/docker/web", $yaml);
 *   synology.buildProject($c, $id);
 */
export func createProject(c as Client, name as string, folder as string, compose as string) {
    if (not regex.matches("^[a-z0-9][a-z0-9_-]*$", $name)) {
        fail("a project name is lowercase letters, digits, _ and -, got " + shown($name));
    }
    def path as string init checkPath($folder);
    if (strings.trim($compose) == "") {
        fail("a project needs its compose.yaml");
    }
    def params as map of string to string init {
        "name": $name,
        "share_path": $path,
        "content": $compose,
        "enable_service_portal": "false",
        "service_portal_protocol": "http"
    };
    def d as json.Value init coreAt($c, "SYNO.Docker.Project", 0, "create", $params, false);
    def id as string init field($d, "/id");
    if ($id == "") {
        fail("SYNO.Docker.Project create: the reply has no id");
    }
    return $id;
}

/**
 * Run a method on a project.
 *
 * @param c {Client} the client
 * @param id {string} the project id
 * @param action {string} the method
 */
func controlProject(c as Client, id as string, action as string) {
    coreAt($c, "SYNO.Docker.Project", 0, $action, {"id": checkProject($id)}, false);
}

/**
 * Pull the images of a project, build what it builds, and start it: what
 * Container Manager's "Build" does.
 *
 * @param c {Client} the client
 * @param id {string} the project id
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func buildProject(c as Client, id as string) {
    controlProject($c, $id, "build");
}

/**
 * Start a project's containers.
 *
 * @param c {Client} the client
 * @param id {string} the project id
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func startProject(c as Client, id as string) {
    controlProject($c, $id, "start");
}

/**
 * Stop a project's containers.
 *
 * @param c {Client} the client
 * @param id {string} the project id
 * @throws {SynologyError} kind `"synology"` as `call`
 */
export func stopProject(c as Client, id as string) {
    controlProject($c, $id, "stop");
}

/**
 * Delete a project and its containers.
 *
 * @param c {Client} the client
 * @param id {string} the project id
 * @param keepFiles {bool} keep the project's folder and `compose.yaml`
 * @throws {SynologyError} kind `"synology"` while it runs, or as `call`
 */
export func deleteProject(c as Client, id as string, keepFiles as bool) {
    def params as map of string to string init {
        "id": checkProject($id),
        "preserve_content": convert.toString($keepFiles)
    };
    coreAt($c, "SYNO.Docker.Project", 0, "delete", $params, false);
}

/**
 * Escape a map key for a JSON Pointer.
 *
 * @param key {string} the key
 * @return {string} the key with `~` and `/` escaped
 */
func pointerToken(key as string) {
    return strings.replace(strings.replace($key, "~", "~0"), "/", "~1");
}

/**
 * The type of a node, `missing` when the pointer does not resolve. Jennifer
 * 0.25.0's `json.typeOf` throws for a missing member instead.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer; "" for the root
 * @return {string} `null`, `bool`, `int`, `float`, `string`, `list`, `map` or `missing`
 */
func kindAt(v as json.Value, ptr as string) {
    if ($ptr == "") {
        return json.typeOf($v);
    }
    if (not json.has($v, $ptr)) {
        return "missing";
    }
    return json.typeOf($v, $ptr);
}

/**
 * Read a node as text, whatever its type.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the text; "" for absent or `null`
 */
func field(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "string") {
        return json.asString($v, $ptr);
    } elseif ($kind == "int") {
        return convert.toString(json.asInt($v, $ptr));
    } elseif ($kind == "float") {
        return convert.toString(json.asFloat($v, $ptr));
    } elseif ($kind == "bool") {
        if (json.asBool($v, $ptr)) {
            return "true";
        }
        return "false";
    }
    return "";
}

/**
 * Read a node as an int: a number (truncated) or a numeric string. DSM sends
 * sizes as strings in places.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number; 0 for absent, `null` or not numeric
 */
func number(v as json.Value, ptr as string) {
    def kind as string init kindAt($v, $ptr);
    if ($kind == "int") {
        return json.asInt($v, $ptr);
    } elseif ($kind == "float") {
        return convert.toInt(json.asFloat($v, $ptr));
    } elseif ($kind == "string") {
        try {
            return convert.toInt(strings.trim(json.asString($v, $ptr)));
        } catch (e) {
            return 0;
        }
    }
    return 0;
}

/**
 * Read a flag: `true`, `1`, `"true"`, `"yes"` or `"1"` are true.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {bool} the flag; false for absent
 */
func flag(v as json.Value, ptr as string) {
    def text as string init strings.lower(field($v, $ptr));
    return $text == "true" or $text == "1" or $text == "yes";
}

/**
 * The pointers of a list's elements.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the list's pointer
 * @return {list of string} `<ptr>/0`, `<ptr>/1`, ...; empty when it is no list
 */
func items(v as json.Value, ptr as string) {
    def out as list of string init [];
    if (kindAt($v, $ptr) != "list") {
        return $out;
    }
    def n as int init json.length($v, $ptr);
    def i as int init 0;
    while ($i < $n) {
        $out[] = $ptr + "/" + convert.toString($i);
        $i = $i + 1;
    }
    return $out;
}
