<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Connecting

## The address

`client` takes a host name, `host:port` or a full URL. A bare host gets
`https://` and port 5001, DSM's HTTPS port:

```jennifer
def c as synology.Client init synology.client("nas.example.com");    # https://nas.example.com:5001
$c = synology.client("https://nas.example.com:443");                 # behind a reverse proxy
```

## Certificates

A NAS usually presents a self-signed certificate. Export it from Control
Panel > Security > Certificate and trust it:

```jennifer
$c = synology.withCaCert($c, fs.readBytes("nas.pem"));
```

`withInsecure` turns checking off. The connection is still encrypted but no
longer authenticated, so anything on the network path could read the
password.

## Logging in

Use an account made for the job, with access to the shares it needs and
nothing else:

```jennifer
$c = synology.login($c, "backup", fs.readString("/run/secrets/nas"));
# ...
$c = synology.logout($c);
```

`login` first asks `SYNO.API.Info` where the APIs live (`discover`): DSM 7
serves most of them from `entry.cgi`, DSM 6 from separate CGIs. Every request
is a POST, so the password and the session id never appear in a URL or a web
server log. The one exception is `upload`, which DSM only accepts with the
session id in the URL.

A session is named (`FileStation` unless `withSessionName` says otherwise).
DSM keeps one session per name and account: a second login under the same
name ends the first one, which then fails with code 107. Give programs that
run at the same time names of their own.

## 2-step verification

An account with 2-step verification refuses `login` with code 403 (the
error's `code` field). Log in
with the current code instead; with a device name, DSM trusts the device and
hands out an id that skips the code next time:

```jennifer
$c = synology.loginOtp($c, "admin", $password, "123456", "nightly-backup");
fs.writeString("device-id", $c.deviceId);

# later, without a code
$c = synology.withDeviceId(synology.client("nas.example.com"), fs.readString("device-id"), "nightly-backup");
$c = synology.login($c, "admin", $password);
```

Keep the device id as secret as the password: with it, the password alone is
enough again. Revoke it in DSM under Personal > Security > Trusted devices.

## Keeping a session

The session id can be stored and reused. Call `discover` after
`withSession`, or the first request asks for each API's location.
`refreshToken` gets a new CSRF token when only the sid was kept:

```jennifer
$c = synology.withSession(synology.client("nas.example.com"), $sid, $token);
$c = synology.discover($c);
```

A session ends after DSM's idle timeout (Control Panel > Security), or when
someone logs in under the same name. Requests then fail with code 106, 107 or
119, and the message says to log in again.

## Any API

`call` reaches what the typed verbs do not cover. Look the API up in
Synology's developer guides or in the requests the DSM web interface makes:

```jennifer
def u as json.Value init synology.call($c, "SYNO.Core.System.Utilization", 1, "get", {});
io.printf("CPU load %v\n", json.get($u, "/cpu/user_load"));
```

Version 0 means the newest the host speaks. `apiInfo` says which versions
that is. Parameters that DSM takes as JSON, such as a list of paths, go in
already encoded: `json.encode(["/a", "/b"])`.

An API whose `requestFormat` is `JSON` takes every value JSON-encoded.
`call` does that: a value that already is JSON (a number, `true`/`false`,
a list, an object, a quoted string) goes as it is, anything else as a JSON
string. So a name made only of digits reaches such an API as a number.

## Timeouts and retries

`withTimeout` sets each request's idle timeout, 30 s by default. `withRetries`
retries reads answered 429 or 5xx; writes are never retried.
