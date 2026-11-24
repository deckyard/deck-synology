<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

`@deckyard/synology` is a client for the Synology™ DSM™ Web API (`/webapi`,
HTTPS, port 5001 by default). It covers login with 2-step codes and trusted
devices, the system summary, File Station™ (shares, listing, folders, rename,
copy, move, delete, upload, download), Virtual Machine Manager, users, groups,
shares and permissions, certificates, snapshots, health, updates, power,
packages, services, scheduled tasks, Hyper Backup™ and Container Manager™
(containers, images, Compose projects). `call` reaches any other API.

Not in scope:

- **Creating or deleting shares through File Station.** `mkdir` and `delete`
  refuse a bare `/share`; shares are an administration task (`SYNO.Core`).
- **Anything that runs on the NAS itself.** The deck is a remote client: no
  `exec`, no SSH, capability `net` only.
- **`jennifer-tiny`.** It has no `net` capability.

## Decisions

- **The documented Web API, discovered.** DSM's `SYNO.API.Info` says which CGI
  path and version range each API has, and every reply is `{"success": bool,
  "data" | "error"}`. `discover` asks for every API in `KNOWN_APIS` in one
  query (a trailing `.` asks for a whole family) and caches the answers as
  `ApiInfo` in `Client.apis`. `login` discovers first when the cache is empty;
  after `withSession` the caller runs `discover`. `apiInfo` falls back to a
  live query for an API not in the cache.
- **Version policy.** Documented APIs are called at the version the deck was
  written for, stepping down to the host's newest but not below the lowest
  version the verb supports. Undocumented `SYNO.Core` APIs use the host's
  oldest version by default, as DSM's own web interface does, or an explicit
  one. Virtual Machine Manager uses a fixed version 1. `call` with version 0
  uses the host's newest.
- **Request shape.** Every call is a form POST to `/webapi/<cgi>` with the
  session id as `_sid` and the CSRF token as `X-SYNO-TOKEN`. An API whose
  `requestFormat` is `JSON` gets each parameter value JSON-encoded; a string
  that already parses as JSON is sent as is, so a numeric-looking string
  parameter must be encoded by the verb.
- **Validate before sending.** Paths must start with `/<share>` and contain no
  empty, `.` or `..` segment and no control character; names, VMM labels
  (no `,` or `\`, rather than escapes the deck cannot verify), container,
  image and project names are checked before DSM sees them. A CGI path from
  `SYNO.API.Info` that does not match the expected pattern, or contains `..`,
  is refused.
- **Background tasks.** File Station delete, copy and move, and VMM create and
  power actions run as DSM tasks. The deck polls them (`withPollInterval`,
  1 s by default) until they finish or `withWaitTimeout` (1 hour by default)
  runs out. The bound is a client setting rather than an argument. The VMM
  wait pauses at most 30 s between polls, because VMM drops a finished task's
  record after about a minute.
- **Missing is not a failure in `exists` and `stat`.** DSM reports a missing
  path as code 408 inside a successful reply; the deck reads it from there.
- **Downloads check the content type.** A refusal arrives as JSON in place of
  the file, so `download` tells the two apart before returning bytes.
- **2-step login.** `login` failing with DSM code 403 points to `loginOtp`;
  `loginOtp` with a device name asks for a trusted-device token, kept in
  `Client.deviceId` for later logins through `withDeviceId`.
- **Retries for reads only.** A read retries 429 and 5xx answers
  `withRetries` times with a 500 ms backoff (through `http`); a write is never
  retried, since DSM gives no idempotency guarantee.
- **One module.** All APIs share the transport, discovery and error tables, so
  the deck is a single `src/synology.j` built on the interpreter's `http`,
  `multipart` and `uri` modules.

## Errors

- Every throw of kind `"synology"` (`ERROR_KIND`) is a `SynologyError`:
  `status` is the HTTP status of a non-2xx reply, `code` DSM's error code,
  both 0 when absent. The message carries DSM's code translated to text
  (common codes, and the Auth, File Station and VMM tables for codes from
  400 up), with per-path `error.errors` entries, and "log in again" for an
  expired or invalid session.
- A reached cap (`download`'s `maxBytes`, an `http` body cap) is kind
  `"limit"`, message `synology: <API> <method>: ...`.
- A background task still running after the wait limit is kind `"timeout"`.
- A transport failure (refused, reset, unreachable, DNS, TLS, a close
  before any reply) is the `http` module's `net.NetError`, kind `"net"`,
  passed on unchanged so its `reason`, `sent` and `replied` stay readable.
- Any other failure of the exchange is rewrapped as a `SynologyError` with
  status and code 0.
- `login` recognises the 2-step case by `code == 403`, never by message text.

## Security and limits

- HTTPS by default. A bare host or `host:port` becomes `https://`; an explicit
  URL is taken as given. A NAS usually presents a self-signed certificate:
  `withCaCert` trusts it, `withInsecure` turns verification off (still
  encrypted, no longer authenticated).
- Each request has an idle timeout (`withTimeout`, 30 s by default).
- `download` refuses a reply over `maxBytes` (64 MiB with 0); `files` and
  `shares` page at `PAGE_SIZE`.
- Strings a caller or host supplied are cut to 60 characters, with anything
  but printable ASCII replaced, before they appear in an error message, so a
  message stays one line and carries no terminal escape.
- The password and one-time code go only into the login request. `sid`,
  `synoToken` and the device id are held in the `Client` value; the caller
  decides whether to persist them.

## Testing and validation

- `src/synology_test.j` (53 tests) is a white-box overlay against a loopback
  fake built on `httpd`: one canned reply per request in order, with each
  request's method, path, query, form fields, token header and body recorded.
  A canned DSM 7 `SYNO.API.Info` answer seeds logged-in test clients.
- `examples/backup.j` needs a NAS, so CI only parses it.
- DSM 6.2 or newer is the stated target, DSM 7 the main one; Container
  Manager needs DSM 7.2.

## Known limitations and open questions

- `SYNO.Core.*` and `SYNO.Docker.*` codes from 400 up have no table and read
  "unknown error code" (the number is still in `code`).
- Plain `http://` is accepted when given explicitly; there is no
  loopback-only rule.
- `call` is never retried, whatever the API.

## Dependencies on the interpreter

- Floor `jennifer >=0.27.0`; the default binary only. The UTF-8 codecs of
  `encoding.encode` / `decode` and `strings.replicate` arrived in 0.27.0.
- The bundled `http` (send, raw and byte bodies, retries, TLS options),
  `multipart` and `uri` modules, and the `httpd` library in the tests.
- Thrown structs classified by kind (`jennifer` `6abf345`, the error-struct
  work of M28.51 to M28.57), and transport failures as `net.NetError`
  (M28.65).
