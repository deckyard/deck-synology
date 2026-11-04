# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * White-box tests for synology: jennifer test src/synology_test.j
 *
 * The checking and parsing helpers are tested directly. The requests go to an
 * `httpd` server on a loopback port that answers with canned DSM replies and
 * hands back what it received.
 */
use httpd;
use task;
use testing;

/** A canned reply. */
def struct Reply {
    status as int,
    contentType as string,
    body as string
};

/** One request as the fake server saw it. */
def struct Seen {
    method as string,
    path as string,
    query as map of string to string,
    form as map of string to string,
    token as string,
    contentType as string,
    body as bytes
};

/** A running fake server. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

/**
 * The query parameters the deck puts in a URL. Not `httpd.rawQuery`: 0.25.0
 * does not have it.
 *
 * @param req {httpd.Request} the request
 * @return {map of string to string} the parameters that are set
 */
func queryOf(req as httpd.Request) {
    def out as map of string to string init {};
    for (def key in ["api", "version", "method", "_sid"]) {
        def value as string init httpd.query($req, $key);
        if ($value != "") {
            $out[$key] = $value;
        }
    }
    return $out;
}

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        def body as bytes init httpd.body($req);
        def sent as string init httpd.header($req, "Content-Type");
        def fields as map of string to string init {};
        if (strings.startsWith($sent, "application/x-www-form-urlencoded")) {
            $fields = uri.parseQuery(convert.stringFromBytes($body, "utf-8"));
        }
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            query: queryOf($req),
            form: $fields,
            token: httpd.header($req, "X-SYNO-TOKEN"),
            contentType: $sent,
            body: $body
        };
        httpd.setHeader($req, "Content-Type", $r.contentType);
        httpd.respond($req, $r.status, $r.body);
    }
    return $seen;
}

/**
 * Start a fake server that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of list of Seen init spawn {
        return serve($srv, $replies);
    };
    return Fake{srv: $srv, url: "http://" + httpd.address($srv), t: $t};
}

/**
 * Stop a fake server.
 *
 * @param f {Fake} the server
 * @return {list of Seen} what it received
 */
func finish(f as Fake) {
    def seen as list of Seen init task.wait($f.t);
    httpd.shutdown($f.srv);
    return $seen;
}

/**
 * A successful reply wrapping `data`.
 *
 * @param data {string} the JSON of `data`
 * @return {Reply} the reply
 */
func ok(data as string) {
    return Reply{
        status: 200,
        contentType: "application/json",
        body: '{"success":true,"data":' + $data + '}'
    };
}

/**
 * A failed reply.
 *
 * @param error {string} the JSON of `error`
 * @return {Reply} the reply
 */
func refused(error as string) {
    return Reply{
        status: 200,
        contentType: "application/json",
        body: '{"success":false,"error":' + $error + '}'
    };
}

/** What SYNO.API.Info answers on a DSM 7 host. */
def const DSM7_APIS as string init '{' +
    '"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},' +
    '"SYNO.DSM.Info":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.FileStation.CreateFolder":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.FileStation.Rename":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.FileStation.Delete":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.FileStation.CopyMove":{"path":"entry.cgi","minVersion":1,"maxVersion":3},' +
    '"SYNO.FileStation.Upload":{"path":"entry.cgi","minVersion":1,"maxVersion":3},' +
    '"SYNO.FileStation.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.Virtualization.API.Guest":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Virtualization.API.Guest.Action":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Virtualization.API.Guest.Image":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Virtualization.API.Host":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Virtualization.API.Network":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Virtualization.API.Storage":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Virtualization.API.Task.Info":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.User":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Group":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Group.Member":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Share":{"path":"entry.cgi","minVersion":1,"maxVersion":1,' +
    '"requestFormat":"JSON"},' +
    '"SYNO.Core.Share.Permission":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Share.Snapshot":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.Core.Certificate":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Certificate.CRT":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Certificate.Service":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.System":{"path":"entry.cgi","minVersion":1,"maxVersion":3},' +
    '"SYNO.Core.System.Utilization":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Storage.CGI.Storage":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Upgrade.Server":{"path":"entry.cgi","minVersion":1,"maxVersion":4},' +
    '"SYNO.Core.Package":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.Core.Package.Control":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Core.Terminal":{"path":"entry.cgi","minVersion":1,"maxVersion":3},' +
    '"SYNO.Core.FileServ.SMB":{"path":"entry.cgi","minVersion":1,"maxVersion":3},' +
    '"SYNO.Core.FileServ.NFS":{"path":"entry.cgi","minVersion":1,"maxVersion":2},' +
    '"SYNO.Core.TaskScheduler":{"path":"entry.cgi","minVersion":1,"maxVersion":4},' +
    '"SYNO.Backup.Task":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Docker.Container":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Docker.Container.Log":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Docker.Image":{"path":"entry.cgi","minVersion":1,"maxVersion":1},' +
    '"SYNO.Docker.Project":{"path":"entry.cgi","minVersion":1,"maxVersion":1}' +
    '}';

/**
 * A logged-in client for a fake server that already knows the DSM 7 APIs, so
 * a test's first request is its own.
 *
 * @param f {Fake} the server
 * @return {Client} the client
 */
func session(f as Fake) {
    def c as Client init withSession(client($f.url), "sid-1", "tok-1");
    def d as json.Value init json.decode(DSM7_APIS);
    for (def name in json.keys($d)) {
        def p as string init "/" + $name;
        $c.apis[$name] = ApiInfo{
            name: $name,
            path: json.asString($d, $p + "/path"),
            minVersion: json.asInt($d, $p + "/minVersion"),
            maxVersion: json.asInt($d, $p + "/maxVersion"),
            requestFormat: field($d, $p + "/requestFormat")
        };
    }
    $c.pollMs = 1;
    return $c;
}

/**
 * A form field of a request, "" when it is absent.
 *
 * @param s {Seen} the request
 * @param key {string} the field
 * @return {string} its value
 */
func formOf(s as Seen, key as string) {
    if (maps.has($s.form, $key)) {
        return $s.form[$key];
    }
    return "";
}

/**
 * The message of the deck's error a request fails with, "" when it passes.
 * Each test names what it calls; there are no closures.
 *
 * @param e {Error} the error
 * @return {string} its message
 */
func messageOf(e as Error) {
    testing.assertEqual($e.kind, ERROR_KIND);
    return $e.message;
}

/**
 * Fail a test whose call was meant to throw.
 */
func missed() {
    throw Error{kind: "test", message: "the call did not fail"};
}

func testBaseUrl() {
    testing.assertEqual(client("nas.example.com").url, "https://nas.example.com:5001");
    testing.assertEqual(client("10.0.0.5:5000").url, "https://10.0.0.5:5000");
    testing.assertEqual(client("https://nas:5001/webapi/").url, "https://nas:5001");
    testing.assertEqual(client("http://nas:5000").url, "http://nas:5000");
    testing.assertEqual(client("fe80::1").url, "https://[fe80::1]:5001");
    testing.assertEqual(client("[::1]:5001").url, "https://[::1]:5001");
    try {
        client("  ");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "synology: the host is empty");
    }
}

func testClientSettings() {
    def c as Client init client("nas");
    testing.assertEqual($c.sessionName, "FileStation");
    $c = withSessionName(
        withPollInterval(withRetries(withTimeout(withInsecure($c), 5000), 2), 50),
        "backup-job");
    testing.assertTrue($c.tls.skipVerify);
    testing.assertEqual($c.timeoutMs, 5000);
    testing.assertEqual($c.retries, 2);
    testing.assertEqual($c.pollMs, 50);
    testing.assertEqual($c.sessionName, "backup-job");
    $c = withCaCert($c, convert.bytesFromString("PEM", "utf-8"));
    testing.assertFalse($c.tls.skipVerify);
    def trusted as Client init withDeviceId($c, "dev-9", "ci");
    testing.assertEqual($trusted.deviceId, "dev-9");
    testing.assertEqual($trusted.deviceName, "ci");
    try {
        withSessionName($c, "two words");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a session name is letters");
    }
    try {
        withSession($c, "sid\r\nX-Evil: 1", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "no control characters");
    }
}

func testPathsAreChecked() {
    testing.assertEqual(checkPath("/photo/2024/"), "/photo/2024");
    testing.assertEqual(checkPath("/photo"), "/photo");
    def bads as list of string init [
        "",
        "/",
        "photo/a",
        "/photo/../etc",
        "/photo//a",
        "/photo/./a"
    ];
    $bads[] = "/photo/a\nb";
    for (def bad in $bads) {
        try {
            checkPath($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "synology: a");
        }
    }
    testing.assertEqual(parentOf("/photo/2024/a.jpg"), "/photo/2024");
    testing.assertEqual(nameOf("/photo/2024/a.jpg"), "a.jpg");
    for (def bad in ["", ".", "..", "a/b", "a\tb"]) {
        try {
            checkName($bad);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a name holds no /");
        }
    }
}

func testCodesMeanWhatTheirApiSays() {
    testing.assertEqual(codeText("SYNO.API.Auth", 400), "no such account or incorrect password");
    testing.assertEqual(
        codeText("SYNO.FileStation.List", 400),
        "invalid parameter of file operation");
    testing.assertEqual(codeText("SYNO.FileStation.Delete", 408), "no such file or directory");
    testing.assertEqual(codeText("SYNO.DSM.Info", 106), "session timeout");
    testing.assertEqual(codeText("SYNO.DSM.Info", 400), "unknown error code");
    testing.assertEqual(codeText("SYNO.FileStation.List", 999), "unknown error code");
    def doc as json.Value init json.decode(
        '{"success":false,"error":{"code":1000,"errors":[{"code":408,"path":"/a/b"},' +
            '{"code":414}]}}');
    testing.assertEqual(
        failureText($doc, "SYNO.FileStation.CopyMove"),
        "failed to copy files/folders (code 1000) [\"/a/b\": no such file or directory " +
            "(code 408); " +
            "file already exists (code 414)]");
    testing.assertEqual(
        failureText(json.decode('{"success":false,"error":{"code":119}}'), "SYNO.DSM.Info"),
        "invalid session (code 119); log in again");
}

func testLoginDiscoversFirst() {
    def f as Fake init fake([
        ok(DSM7_APIS),
        ok('{"sid":"abc","synotoken":"tok","is_portal_port":false}')
    ]);
    def c as Client init login(client($f.url), "backup", "p&ss=word");
    def seen as list of Seen init finish($f);
    testing.assertEqual($c.sid, "abc");
    testing.assertEqual($c.synoToken, "tok");
    testing.assertEqual(len($c.apis), json.length(json.decode(DSM7_APIS)));
    testing.assertEqual($c.apis["SYNO.Core.Share"].requestFormat, "JSON");
    testing.assertEqual($seen[0].path, "/webapi/query.cgi");
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.API.Info");
    testing.assertEqual(formOf($seen[0], "query"), KNOWN_APIS);
    testing.assertEqual($seen[1].method, "POST");
    testing.assertEqual($seen[1].path, "/webapi/entry.cgi");
    testing.assertEqual(formOf($seen[1], "api"), "SYNO.API.Auth");
    testing.assertEqual(formOf($seen[1], "version"), "6");
    testing.assertEqual(formOf($seen[1], "method"), "login");
    testing.assertEqual(formOf($seen[1], "account"), "backup");
    testing.assertEqual(formOf($seen[1], "passwd"), "p&ss=word");
    testing.assertEqual(formOf($seen[1], "session"), "FileStation");
    testing.assertEqual(formOf($seen[1], "format"), "sid");
    testing.assertEqual(formOf($seen[1], "enable_syno_token"), "yes");
    # The password travels in the body, never in the URL.
    testing.assertEqual(len($seen[1].query), 0);
    testing.assertEqual(formOf($seen[1], "_sid"), "");
}

func testLoginStepsDownToOlderVersions() {
    def old as string init '{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":4}}';
    def f as Fake init fake([ok($old), ok('{"sid":"s4"}')]);
    def c as Client init login(client($f.url), "a", "b");
    def seen as list of Seen init finish($f);
    testing.assertEqual($c.sid, "s4");
    testing.assertEqual($seen[1].path, "/webapi/auth.cgi");
    testing.assertEqual(formOf($seen[1], "version"), "4");
    def ancient as string init '{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,' +
        '"maxVersion":2}}';
    def g as Fake init fake([ok($ancient)]);
    try {
        login(client($g.url), "a", "b");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.API.Auth: the host speaks versions 1 to 2, the deck needs 3 to 6");
    }
    finish($g);
}

func testDiscoverRefusesWhatIsNotDsm() {
    def f as Fake init fake([
        ok('{}'),
        ok('{"SYNO.API.Auth":{"path":"../x.cgi","minVersion":1,"maxVersion":6}}')
    ]);
    def c as Client init client($f.url);
    try {
        discover($c);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "synology: the host lists no SYNO.API.Auth; is it DSM?");
    }
    try {
        discover($c);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an unusable path \"../x.cgi\"");
    }
    finish($f);
}

func testLoginNeedsTheCode() {
    def f as Fake init fake([refused('{"code":403}'), refused('{"code":400}')]);
    def c as Client init session($f);
    try {
        login($c, "admin", "x");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.API.Auth login: 2-step verification code required (code 403); " +
                "use loginOtp");
    }
    try {
        login($c, "admin", "x");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.API.Auth login: no such account or incorrect password (code 400)");
    }
    def seen as list of Seen init finish($f);
    # A new login never presents the old session.
    testing.assertEqual(formOf($seen[0], "_sid"), "");
    testing.assertEqual($seen[0].token, "");
}

func testLoginOtpTrustsTheDevice() {
    def f as Fake init fake([ok('{"sid":"s2","did":"dev-7"}'), ok('{"sid":"s3"}')]);
    def c as Client init loginOtp(session($f), "admin", "x", " 123456 ", "jennifer-ci");
    testing.assertEqual($c.sid, "s2");
    testing.assertEqual($c.deviceId, "dev-7");
    $c = login($c, "admin", "x");
    def seen as list of Seen init finish($f);
    testing.assertEqual(formOf($seen[0], "otp_code"), "123456");
    testing.assertEqual(formOf($seen[0], "enable_device_token"), "yes");
    testing.assertEqual(formOf($seen[0], "device_name"), "jennifer-ci");
    testing.assertEqual(formOf($seen[1], "device_id"), "dev-7");
    # The Login guide sends the device name with the id.
    testing.assertEqual(formOf($seen[1], "device_name"), "jennifer-ci");
    testing.assertEqual(formOf($seen[1], "otp_code"), "");
}

func testLogout() {
    def f as Fake init fake([ok('null')]);
    def c as Client init logout(session($f));
    def seen as list of Seen init finish($f);
    testing.assertEqual($c.sid, "");
    testing.assertEqual($c.synoToken, "");
    testing.assertEqual(formOf($seen[0], "method"), "logout");
    testing.assertEqual(formOf($seen[0], "session"), "FileStation");
    testing.assertEqual(formOf($seen[0], "_sid"), "sid-1");
    # Without a session there is nothing to end, and nothing is sent.
    testing.assertEqual(logout($c).sid, "");
}

func testInfo() {
    def f as Fake init fake([
        ok(
            '{"model":"DS920+","ram":4096,"serial":"2010PDN123456","temperature":41,' +
                '"temperature_warn":false,"time":"Tue Nov 3 2026","uptime":123456,' +
                '"version":"69057","version_string":"DSM 7.2.1-69057 Update 5"}')
    ]);
    def i as SystemInfo init info(session($f));
    def seen as list of Seen init finish($f);
    testing.assertEqual($i.model, "DS920+");
    testing.assertEqual($i.serial, "2010PDN123456");
    testing.assertEqual($i.version, "DSM 7.2.1-69057 Update 5");
    testing.assertEqual($i.build, "69057");
    testing.assertEqual($i.ramMb, 4096);
    testing.assertEqual($i.uptime, 123456);
    testing.assertEqual($i.temperature, 41);
    testing.assertFalse($i.overheated);
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.DSM.Info");
    testing.assertEqual(formOf($seen[0], "version"), "2");
    testing.assertEqual(formOf($seen[0], "method"), "getinfo");
    testing.assertEqual(formOf($seen[0], "_sid"), "sid-1");
    testing.assertEqual($seen[0].token, "tok-1");
}

func testSharesArePaged() {
    def f as Fake init fake([
        ok(
            '{"offset":0,"total":3,"shares":[' +
                '{"isdir":true,"name":"homes","path":"/homes",' +
                '"additional":{"real_path":"/volume1/homes",' +
                '"volume_status":{"freespace":"1000","totalspace":4000,"readonly":false}}},' +
                '{"isdir":true,"name":"photo","path":"/photo",' +
                '"additional":{"real_path":"/volume1/photo"}}]}'),
        ok('{"offset":2,"total":3,"shares":[{"isdir":true,"name":"usb","path":"/usbshare1",' +
            '"additional":{"volume_status":{"readonly":true}}}]}')
    ]);
    def got as list of Share init shares(session($f));
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($got), 3);
    testing.assertEqual($got[0].name, "homes");
    testing.assertEqual($got[0].realPath, "/volume1/homes");
    testing.assertEqual($got[0].free, 1000);
    testing.assertEqual($got[0].total, 4000);
    testing.assertEqual($got[2].path, "/usbshare1");
    testing.assertTrue($got[2].readOnly);
    testing.assertEqual(formOf($seen[0], "method"), "list_share");
    testing.assertEqual(formOf($seen[0], "offset"), "0");
    testing.assertEqual(formOf($seen[0], "limit"), "1000");
    testing.assertEqual(formOf($seen[0], "additional"), '["real_path","volume_status"]');
    testing.assertEqual(formOf($seen[1], "offset"), "2");
}

func testFiles() {
    def f as Fake init fake([
        ok(
            '{"offset":0,"total":2,"files":[' +
                '{"isdir":true,"name":"2024","path":"/photo/2024","additional":{"size":0,' +
                '"time":{"mtime":1700000000}}},' +
                '{"isdir":false,"name":"a.jpg","path":"/photo/a.jpg",' +
                '"additional":{"size":"20480","time":{"mtime":1700000100}}}]}')
    ]);
    def got as list of File init files(session($f), "/photo/");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($got), 2);
    testing.assertTrue($got[0].isDir);
    testing.assertEqual($got[1].name, "a.jpg");
    testing.assertEqual($got[1].size, 20480);
    testing.assertEqual($got[1].modified, 1700000100);
    testing.assertEqual(formOf($seen[0], "method"), "list");
    testing.assertEqual(formOf($seen[0], "folder_path"), "/photo");
    testing.assertEqual(formOf($seen[0], "sort_by"), "name");
}

func testStatAndExists() {
    def entry as string init '{"files":[{"isdir":false,"name":"a.jpg","path":"/photo/a.jpg",' +
        '"additional":{"size":5,"time":{"mtime":7}}}]}';
    def f as Fake init fake([
        ok($entry),
        ok($entry),
        ok('{"files":[{"code":408,"path":"/photo/b.jpg"}]}'),
        refused('{"code":408}'),
        ok('{"files":[{"code":408,"path":"/photo/b.jpg"}]}'),
        refused('{"code":105}')
    ]);
    def c as Client init session($f);
    def s as File init stat($c, "/photo/a.jpg");
    testing.assertEqual($s.size, 5);
    testing.assertEqual($s.modified, 7);
    testing.assertTrue(exists($c, "/photo/a.jpg"));
    testing.assertFalse(exists($c, "/photo/b.jpg"));
    testing.assertFalse(exists($c, "/photo/b.jpg"));
    try {
        stat($c, "/photo/b.jpg");
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.FileStation.List getinfo: /photo/b.jpg: no such file or " +
                "directory (code 408)");
    }
    try {
        exists($c, "/photo/c.jpg");
        missed();
    } catch (e) {
        testing.assertContains(
            messageOf($e),
            "the logged in session does not have permission (code 105)");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(formOf($seen[0], "path"), '["/photo/a.jpg"]');
}

func testMkdirAndRename() {
    def f as Fake init fake([
        ok('{"folders":[{"isdir":true,"name":"06","path":"/backup/2024/06"}]}'),
        ok('{"files":[{"isdir":false,"name":"b.txt","path":"/backup/b.txt"}]}')
    ]);
    def c as Client init session($f);
    def made as File init mkdir($c, "/backup/2024/06", true);
    def renamed as File init rename($c, "/backup/a.txt", "b.txt");
    def seen as list of Seen init finish($f);
    testing.assertEqual($made.path, "/backup/2024/06");
    testing.assertTrue($made.isDir);
    testing.assertEqual($renamed.path, "/backup/b.txt");
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.FileStation.CreateFolder");
    testing.assertEqual(formOf($seen[0], "folder_path"), '["/backup/2024"]');
    testing.assertEqual(formOf($seen[0], "name"), '["06"]');
    testing.assertEqual(formOf($seen[0], "force_parent"), "true");
    testing.assertEqual(formOf($seen[1], "path"), '["/backup/a.txt"]');
    testing.assertEqual(formOf($seen[1], "name"), '["b.txt"]');
    for (def share in ["/backup", "/backup/"]) {
        try {
            mkdir($c, $share, false);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), "a shared folder is not created");
        }
    }
    try {
        rename($c, "/backup/a.txt", "../b.txt");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a name holds no /");
    }
}

func testDeleteWaitsForItsTask() {
    def f as Fake init fake([
        ok('{"taskid":"FileStation_51D00B7912CDE0B0"}'),
        ok('{"finished":false,"progress":0.5}'),
        ok('{"finished":true,"progress":1}')
    ]);
    def c as Client init session($f);
    delete($c, "/backup/old");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 3);
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.FileStation.Delete");
    testing.assertEqual(formOf($seen[0], "method"), "start");
    testing.assertEqual(formOf($seen[0], "path"), '["/backup/old"]');
    testing.assertEqual(formOf($seen[0], "recursive"), "true");
    testing.assertEqual(formOf($seen[1], "method"), "status");
    testing.assertEqual(formOf($seen[2], "taskid"), "FileStation_51D00B7912CDE0B0");
    try {
        delete($c, "/backup");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a shared folder is not deleted");
    }
}

func testCopyAndMove() {
    def f as Fake init fake([
        ok('{"taskid":"t1"}'),
        ok('{"finished":true}'),
        ok('{"taskid":"t2"}'),
        ok('{"finished":true,"errors":[{"code":414,"path":"/archive/a.txt"}]}'),
        ok('{"taskid":"t3"}'),
        refused('{"code":1002}')
    ]);
    def c as Client init session($f);
    testing.assertEqual(copy($c, "/backup/a.txt", "/archive", false), "/archive/a.txt");
    try {
        move($c, "/backup/a.txt", "/archive/", true);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.FileStation.CopyMove: \"/archive/a.txt\": file already exists " +
                "(code 414)");
    }
    try {
        copy($c, "/backup/a.txt", "/archive", false);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.FileStation.CopyMove status: an error occurred at the " +
                "destination (code 1002)");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(formOf($seen[0], "version"), "3");
    testing.assertEqual(formOf($seen[0], "dest_folder_path"), "/archive");
    testing.assertEqual(formOf($seen[0], "remove_src"), "false");
    # Without overwrite, DSM refuses an existing target rather than skip it.
    testing.assertEqual(formOf($seen[0], "overwrite"), "");
    testing.assertEqual(formOf($seen[2], "remove_src"), "true");
    testing.assertEqual(formOf($seen[2], "overwrite"), "true");
}

func testUploadSendsMultipart() {
    def f as Fake init fake([ok('{"blSkip":false,"file":"db.sql.gz","pid":1,"progress":100}')]);
    def payload as bytes init convert.bytesFromString(
        "hello\r\n--not-a-boundary" + convert.fromCodepoint(0),
        "utf-8");
    def path as string init upload(session($f), "/backup/db", "db.sql.gz", $payload, true);
    def seen as list of Seen init finish($f);
    testing.assertEqual($path, "/backup/db/db.sql.gz");
    testing.assertEqual($seen[0].path, "/webapi/entry.cgi");
    testing.assertEqual($seen[0].query["api"], "SYNO.FileStation.Upload");
    testing.assertEqual($seen[0].query["version"], "2");
    testing.assertEqual($seen[0].query["method"], "upload");
    testing.assertEqual($seen[0].query["_sid"], "sid-1");
    testing.assertEqual($seen[0].token, "tok-1");
    def parts as list of multipart.Part init multipart.parse($seen[0].contentType, $seen[0].body);
    def names as list of string init [];
    for (def p in $parts) {
        $names[] = $p.name;
    }
    # The file has to come last.
    testing.assertEqual($names, ["path", "create_parents", "overwrite", "file"]);
    testing.assertEqual(multipart.text($parts[0]), "/backup/db");
    testing.assertEqual($parts[3].filename, "db.sql.gz");
    testing.assertEqual($parts[3].data, $payload);
}

func testUploadFailure() {
    def f as Fake init fake([refused('{"code":1805}')]);
    try {
        upload(session($f), "/backup", "a.txt", convert.bytesFromString("x", "utf-8"), false);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.FileStation.Upload upload: can't overwrite or skip the existing " +
                "file (code 1805)");
    }
    def seen as list of Seen init finish($f);
    def parts as list of multipart.Part init multipart.parse($seen[0].contentType, $seen[0].body);
    testing.assertEqual(len($parts), 3);
}

func testDownload() {
    def zip as string init "PK" + convert.fromCodepoint(3) + convert.fromCodepoint(4) + " archive";
    def f as Fake init fake([
        Reply{status: 200, contentType: "application/octet-stream", body: $zip},
        refused('{"code":408}')
    ]);
    def c as Client init session($f);
    def got as bytes init download($c, "/photo/2024", 0);
    testing.assertEqual(convert.stringFromBytes($got, "utf-8"), $zip);
    try {
        download($c, "/photo/missing.jpg", 0);
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.FileStation.Download download: no such file or directory (code 408)");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(formOf($seen[0], "path"), '["/photo/2024"]');
    testing.assertEqual(formOf($seen[0], "mode"), "download");
    testing.assertEqual(formOf($seen[0], "_sid"), "sid-1");
}

func testCallAnyApi() {
    def f as Fake init fake([
        ok('{"SYNO.Core.Network":{"path":"entry.cgi","minVersion":1,"maxVersion":3}}'),
        ok('{"cpu_family":"Ryzen"}'),
        ok('{}'),
        refused('{"code":106}')
    ]);
    def c as Client init session($f);
    def d as json.Value init call($c, "SYNO.Core.Network", 0, "get", {"type": "network"});
    testing.assertEqual(json.asString($d, "/cpu_family"), "Ryzen");
    try {
        call($c, "SYNO.Core.Missing", 1, "get", {});
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "synology: the host has no SYNO.Core.Missing");
    }
    try {
        call($c, "SYNO.DSM.Info", 5, "getinfo", {});
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.DSM.Info: the host speaks versions 1 to 2, not 5");
    }
    try {
        call($c, "SYNO.DSM.Info", 0, "getinfo", {});
        missed();
    } catch (e) {
        testing.assertEqual(
            messageOf($e),
            "synology: SYNO.DSM.Info getinfo: session timeout (code 106); log in again");
    }
    try {
        apiInfo($c, "SYNO.FileStation.");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an API name is SYNO.<name>");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(formOf($seen[0], "query"), "SYNO.Core.Network");
    testing.assertEqual(formOf($seen[1], "version"), "3");
    testing.assertEqual(formOf($seen[1], "type"), "network");
    testing.assertEqual(len($seen), 4);
}

func testBrokenReplies() {
    def f as Fake init fake([
        Reply{status: 502, contentType: "text/plain", body: "bad gateway"},
        Reply{status: 200, contentType: "text/html", body: "<html>login</html>"},
        Reply{status: 200, contentType: "application/json", body: '{"data":{}}'}
    ]);
    def c as Client init session($f);
    for (def want in [
        "synology: SYNO.DSM.Info getinfo: HTTP 502",
        "synology: SYNO.DSM.Info getinfo: the reply is not JSON",
        "synology: SYNO.DSM.Info getinfo: the reply has no success flag"
    ]) {
        try {
            info($c);
            missed();
        } catch (e) {
            testing.assertContains(messageOf($e), $want);
        }
    }
    finish($f);
}

func testMessagesQuoteSafely() {
    def long as string init strings.repeat("x", 100);
    testing.assertEqual(shown($long), "\"" + strings.repeat("x", 60) + "...\"");
    testing.assertEqual(
        shown("a" + convert.fromCodepoint(10) + "b" + convert.fromCodepoint(27) + "[31m"),
        "\"a?b?[31m\"");
    try {
        checkPath("relative" + convert.fromCodepoint(10) + "FAKE LOG LINE");
        missed();
    } catch (e) {
        testing.assertFalse(strings.contains(messageOf($e), convert.fromCodepoint(10)));
    }
    try {
        withSessionName(client("nas"), $long + " x");
        missed();
    } catch (e) {
        testing.assertTrue(len(messageOf($e)) < 160);
    }
    testing.assertEqual(statusLine(502, " Bad Gateway "), "HTTP 502 Bad Gateway");
    testing.assertEqual(statusLine(500, ""), "HTTP 500");
    testing.assertEqual(
        statusLine(500, "x" + convert.fromCodepoint(10) + "forged: y"),
        "HTTP 500 x?forged: y");
}

func testIdleTimeout() {
    # http's raw and bytes requests take 0 as no timeout at all.
    testing.assertEqual(idleMs(client("nas")), 30000);
    testing.assertEqual(idleMs(withTimeout(client("nas"), 500)), 500);
}

func testReaders() {
    def d as json.Value init json.decode('{"a":"12","b":3.9,"c":true,"d":"yes","e":null,' +
        '"l":[1,2]}');
    testing.assertEqual(number($d, "/a"), 12);
    testing.assertEqual(number($d, "/b"), 3);
    testing.assertEqual(number($d, "/missing"), 0);
    testing.assertEqual(field($d, "/c"), "true");
    testing.assertEqual(field($d, "/e"), "");
    testing.assertTrue(flag($d, "/c"));
    testing.assertTrue(flag($d, "/d"));
    testing.assertFalse(flag($d, "/missing"));
    testing.assertEqual(items($d, "/l"), ["/l/0", "/l/1"]);
    testing.assertEqual(items($d, "/a"), []);
    testing.assertEqual(pointerToken("a/b~c"), "a~1b~0c");
}

/** A guest as the Virtual Machine Manager guide shows it. */
def const GUEST as string init '{"autorun":2,"description":"web","guest_id":"g-1",' +
    '"guest_name":"web01","status":"shutdown","storage_id":"s-1",' +
    '"storage_name":"Synology - VM Storage 1","vcpu_num":2,"vram_size":2048,' +
    '"vdisks":[{"controller":1,"unmap":false,"vdisk_id":"d-1","vdisk_size":10240}],' +
    '"vnics":[{"mac":"02:11:32:21:f2:1b","model":1,"network_id":"n-1",' +
    '"network_name":"Default VM Network","vnic_id":"v-1"}]}';

func testGuests() {
    def f as Fake init fake([ok('{"guests":[' + GUEST + ']}'), ok(GUEST)]);
    def c as Client init session($f);
    def all as list of Guest init guests($c);
    def one as Guest init guest($c, "web01");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($all), 1);
    testing.assertEqual($all[0].id, "g-1");
    testing.assertEqual($all[0].status, "shutdown");
    testing.assertEqual($all[0].autorun, 2);
    testing.assertEqual($all[0].vcpus, 2);
    testing.assertEqual($all[0].ramMb, 2048);
    testing.assertEqual($all[0].disks[0].sizeMb, 10240);
    testing.assertEqual($all[0].disks[0].controller, 1);
    testing.assertEqual($all[0].nics[0].mac, "02:11:32:21:f2:1b");
    testing.assertEqual($all[0].nics[0].networkName, "Default VM Network");
    testing.assertEqual($one.name, "web01");
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.Virtualization.API.Guest");
    testing.assertEqual(formOf($seen[0], "method"), "list");
    testing.assertEqual(formOf($seen[0], "version"), "1");
    testing.assertEqual(formOf($seen[0], "additional"), "true");
    testing.assertEqual(formOf($seen[1], "method"), "get");
    testing.assertEqual(formOf($seen[1], "guest_name"), "web01");
}

func testCreateGuestWaitsThenResizes() {
    def f as Fake init fake([
        ok('{"task_id":"@users/virtualization_api_guest_create1"}'),
        ok('{"finish":false,"task_info":{"progress":40}}'),
        ok('{"finish":true,"task_info":{"guest_id":"g-1","progress":100,"status":"create"}}'),
        ok("null"),
        ok(GUEST)
    ]);
    def c as Client init session($f);
    def spec as GuestSpec init GuestSpec{
        name: "web01",
        storage: "Synology - VM Storage 1",
        disks: [DiskSpec{sizeMb: 0, image: "debian-12"}, DiskSpec{sizeMb: 20480, image: ""}],
        networks: ["Default VM Network", ""],
        vcpus: 2,
        ramMb: 2048
    };
    def made as Guest init createGuest($c, $spec);
    def seen as list of Seen init finish($f);
    testing.assertEqual($made.id, "g-1");
    testing.assertEqual(len($seen), 5);
    testing.assertEqual(formOf($seen[0], "method"), "create");
    testing.assertEqual(formOf($seen[0], "guest_name"), "web01");
    testing.assertEqual(formOf($seen[0], "storage_name"), "Synology - VM Storage 1");
    testing.assertEqual(
        formOf($seen[0], "vdisks"),
        '[{"create_type":1,"image_name":"debian-12"},{"create_type":0,"vdisk_size":20480}]');
    testing.assertEqual(
        formOf($seen[0], "vnics"),
        '[{"network_name":"Default VM Network"},{"network_id":""}]');
    testing.assertEqual(formOf($seen[1], "api"), "SYNO.Virtualization.API.Task.Info");
    testing.assertEqual(formOf($seen[1], "task_id"), "@users/virtualization_api_guest_create1");
    testing.assertEqual(formOf($seen[3], "method"), "set");
    testing.assertEqual(formOf($seen[3], "vcpu_num"), "2");
    testing.assertEqual(formOf($seen[3], "vram_size"), "2048");
    testing.assertEqual(formOf($seen[4], "method"), "get");
}

func testCreateGuestChecksItsSpec() {
    def c as Client init client("nas");
    def spec as GuestSpec init GuestSpec{
        name: "web01",
        storage: "s",
        disks: [],
        networks: [],
        vcpus: 0,
        ramMb: 0
    };
    try {
        createGuest($c, $spec);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "synology: a virtual machine needs a disk");
    }
    $spec.disks = [DiskSpec{sizeMb: 0, image: ""}];
    try {
        createGuest($c, $spec);
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "synology: a disk has a size or an image");
    }
    $spec.name = "a,b";
    try {
        createGuest($c, $spec);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a virtual machine name is not empty");
    }
}

func testGuestActions() {
    def f as Fake init fake([
        ok("null"),
        ok("null"),
        ok("null"),
        ok("null"),
        ok("null"),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    powerOnGuest($c, "web01");
    shutdownGuest($c, "web01");
    powerOffGuest($c, "web01");
    resizeGuest($c, "web01", 0, 0);
    resizeGuest($c, "web01", 0, 4096);
    renameGuest($c, "web01", "web02");
    setAutorun($c, "web02", "last");
    deleteGuest($c, "web02");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 7);
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.Virtualization.API.Guest.Action");
    testing.assertEqual(formOf($seen[0], "method"), "poweron");
    testing.assertEqual(formOf($seen[1], "method"), "shutdown");
    testing.assertEqual(formOf($seen[2], "method"), "poweroff");
    testing.assertEqual(formOf($seen[3], "vram_size"), "4096");
    testing.assertEqual(formOf($seen[3], "vcpu_num"), "");
    testing.assertEqual(formOf($seen[4], "new_guest_name"), "web02");
    testing.assertEqual(formOf($seen[5], "autorun"), "1");
    testing.assertEqual(formOf($seen[6], "method"), "delete");
    testing.assertEqual(formOf($seen[6], "guest_name"), "web02");
    try {
        setAutorun($c, "web02", "always");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an autorun mode is off, last or on");
    }
}

func testVmInventory() {
    def f as Fake init fake([
        ok('{"hosts":[{"free_cpu_core":30,"free_ram_size":6656,"host_id":"h-1",' +
            '"host_name":"Synology","status":"running","total_cpu_core":32,' +
            '"total_ram_size":8192}]}'),
        ok('{"storages":[{"host_id":"h-1","host_name":"Synology","size":302227,"status":"online",' +
            '"storage_id":"s-1","storage_name":"VM Storage 1","used":32276,' +
            '"volume_path":"/volume1"}]}'),
        ok('{"networks":[{"network_id":"n-1","network_name":"Default VM Network"}]}'),
        ok('{"images":[{"image_id":"i-1","image_name":"debian-12","type":"disk",' +
            '"storages":[{"status":"online","storage_id":"s-1","storage_name":"VM Storage 1"}]}]}')
    ]);
    def c as Client init session($f);
    def hosts as list of VmHost init vmHosts($c);
    def storages as list of VmStorage init vmStorages($c);
    def networks as list of VmNetwork init vmNetworks($c);
    def images as list of VmImage init vmImages($c);
    def seen as list of Seen init finish($f);
    testing.assertEqual($hosts[0].freeCpus, 30);
    testing.assertEqual($hosts[0].totalRamMb, 8192);
    testing.assertEqual($storages[0].usedMb, 32276);
    testing.assertEqual($storages[0].volumePath, "/volume1");
    testing.assertEqual($networks[0].name, "Default VM Network");
    testing.assertEqual($images[0].type, "disk");
    testing.assertEqual($images[0].storages, ["VM Storage 1"]);
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.Virtualization.API.Host");
    testing.assertEqual(formOf($seen[3], "api"), "SYNO.Virtualization.API.Guest.Image");
}

func testImages() {
    def f as Fake init fake([
        ok('{"task_id":"@administrators/virtualization_api_image_create1"}'),
        ok('{"finish":true,"task_info":{"image_id":"i-9","progress":100,"status":"create"}}'),
        ok("null")
    ]);
    def c as Client init session($f);
    def id as string init createImage(
        $c,
        "debian-12",
        "disk",
        "/vm/debian-12.qcow2",
        ["VM Storage 1"]);
    deleteImage($c, "debian-12");
    def seen as list of Seen init finish($f);
    testing.assertEqual($id, "i-9");
    testing.assertEqual(formOf($seen[0], "image_name"), "debian-12");
    testing.assertEqual(formOf($seen[0], "type"), "disk");
    testing.assertEqual(formOf($seen[0], "ds_file_path"), "/vm/debian-12.qcow2");
    testing.assertEqual(formOf($seen[0], "storage_names"), '["VM Storage 1"]');
    testing.assertEqual(formOf($seen[2], "method"), "delete");
    try {
        createImage($c, "x", "vmdk", "/vm/x", ["s"]);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an image type is disk, vdsm or iso");
    }
}

func testVmmCodes() {
    testing.assertEqual(
        coded("SYNO.Virtualization.API.Guest.Action", 903),
        "not enough memory to power on the virtual machine (code 903)");
    testing.assertEqual(coded("SYNO.Virtualization.API.Guest", 403), "name conflict (code 403)");
    testing.assertEqual(
        coded("SYNO.Virtualization.API.Guest", 105),
        "the logged in session does not have permission (code 105)");
}

func testRefreshToken() {
    def f as Fake init fake([ok('{"is_portal_port":false,"synotoken":"fresh"}')]);
    def c as Client init refreshToken(session($f));
    def seen as list of Seen init finish($f);
    testing.assertEqual($c.synoToken, "fresh");
    testing.assertEqual($c.sid, "sid-1");
    testing.assertEqual(formOf($seen[0], "method"), "token");
    testing.assertEqual(formOf($seen[0], "version"), "6");
}

func testJsonRequestFormat() {
    def got as map of string to string init jsonValues({
        "name": "backup",
        "count": "3",
        "flag": "true",
        "paths": '["/a"]',
        "odd": "a\"b"
    });
    testing.assertEqual($got["name"], '"backup"');
    testing.assertEqual($got["count"], "3");
    testing.assertEqual($got["flag"], "true");
    testing.assertEqual($got["paths"], '["/a"]');
    testing.assertEqual($got["odd"], '"a\"b"');
    # Already encoded, as setDefaultCertificate sends its id: as it is.
    testing.assertEqual(jsonValues({"id": json.encode("abc")})["id"], '"abc"');
}

func testUsers() {
    def f as Fake init fake([
        ok('{"offset":0,"total":2,"users":[{"name":"admin","uid":1024,"description":"",' +
            '"email":"","expired":"now"},{"name":"backup","uid":1026,"description":"jobs",' +
            '"email":"ops@example.com","expired":"normal"}]}'),
        ok('{"users":[{"name":"backup","uid":1026,"description":"jobs","expired":"normal"}]}'),
        ok('{"name":"ci","uid":1030}'),
        ok("null"),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of User init users($c);
    def one as User init user($c, "backup");
    def made as User init createUser($c, "ci", "s3cret!", "CI runner", "");
    setUserPassword($c, "ci", "n3w!");
    setUserEnabled($c, "ci", false);
    deleteUser($c, "ci");
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($all), 2);
    testing.assertEqual($all[0].expired, "now");
    testing.assertEqual($all[1].email, "ops@example.com");
    testing.assertEqual($one.uid, 1026);
    testing.assertEqual($made.uid, 1030);
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.Core.User");
    testing.assertEqual(formOf($seen[0], "type"), "local");
    testing.assertEqual(formOf($seen[0], "additional"), '["description","email","expired"]');
    testing.assertEqual(formOf($seen[2], "password"), "s3cret!");
    testing.assertEqual(formOf($seen[2], "description"), "CI runner");
    testing.assertEqual(formOf($seen[2], "email"), "");
    testing.assertEqual(formOf($seen[3], "method"), "set");
    testing.assertEqual(formOf($seen[3], "new_name"), "ci");
    testing.assertEqual(formOf($seen[3], "password"), "n3w!");
    testing.assertEqual(formOf($seen[4], "expired"), "now");
    testing.assertEqual(formOf($seen[5], "method"), "delete");
    try {
        createUser($c, "ci", "", "", "");
        missed();
    } catch (e) {
        testing.assertEqual(messageOf($e), "synology: an account needs a password");
    }
}

func testGroups() {
    def f as Fake init fake([
        ok('{"groups":[{"name":"administrators","gid":101,"description":"System default"}],' +
            '"offset":0,"total":1}'),
        ok('{"users":[{"name":"admin","uid":1024}],"total":1}'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of Group init groups($c);
    def members as list of string init groupMembers($c, "administrators");
    addToGroup($c, "administrators", ["ci"]);
    removeFromGroup($c, "administrators", ["ci", "old"]);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].gid, 101);
    testing.assertEqual($members, ["admin"]);
    testing.assertEqual(formOf($seen[1], "api"), "SYNO.Core.Group.Member");
    testing.assertEqual(formOf($seen[1], "ingroup"), "true");
    testing.assertEqual(formOf($seen[2], "method"), "change");
    testing.assertEqual(formOf($seen[2], "add_member"), '["ci"]');
    testing.assertEqual(formOf($seen[2], "remove_member"), "[]");
    testing.assertEqual(formOf($seen[3], "remove_member"), '["ci","old"]');
}

func testShares() {
    def f as Fake init fake([
        ok('{"name":"backup"}'),
        ok('{"items":[{"name":"admin","is_admin":true,"is_writable":true,"is_readonly":false,' +
            '"is_deny":false},{"name":"guest","is_deny":true},{"name":"ci","is_readonly":true},' +
            '{"name":"nobody"}],"total":4}'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    testing.assertEqual(createShare($c, "backup", "/volume1", "nightly"), "/backup");
    def perms as list of SharePermission init sharePermissions($c, "backup", "user");
    setSharePermission($c, "backup", "group", "users", "ro");
    deleteShare($c, "backup");
    def seen as list of Seen init finish($f);
    # SYNO.Core.Share says requestFormat JSON: every value goes JSON-encoded.
    testing.assertEqual(formOf($seen[0], "name"), '"backup"');
    def settings as json.Value init json.decode(formOf($seen[0], "shareinfo"));
    testing.assertEqual(json.asString($settings, "/vol_path"), "/volume1");
    testing.assertEqual(json.asString($settings, "/desc"), "nightly");
    testing.assertTrue(json.asBool($settings, "/enable_recycle_bin"));
    testing.assertEqual($perms[0].access, "rw");
    testing.assertTrue($perms[0].isAdmin);
    testing.assertEqual($perms[1].access, "deny");
    testing.assertEqual($perms[2].access, "ro");
    testing.assertEqual($perms[3].access, "none");
    testing.assertEqual(formOf($seen[1], "user_group_type"), "local_user");
    testing.assertEqual(formOf($seen[1], "action"), "enum");
    testing.assertEqual(formOf($seen[2], "user_group_type"), "local_group");
    testing.assertEqual(
        formOf($seen[2], "permissions"),
        '[{"is_custom":false,"name":"users","is_writable":false,"is_readonly":true,' +
            '"is_deny":false}]');
    testing.assertEqual(formOf($seen[3], "name"), '"backup"');
    try {
        createShare($c, "x", "volume1", "");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a share is a name on a volume");
    }
    try {
        setSharePermission($c, "backup", "user", "ci", "write");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an access is rw, ro, deny or none");
    }
    try {
        sharePermissions($c, "backup", "team");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a permission is for a user or a group");
    }
}

/** A certificate list as DSM 7 answers it. */
def const CERTS as string init '{"certificates":[{"id":"Abc123","desc":"",' +
    '"is_default":true,"subject":{"common_name":"nas.example.com"},' +
    '"issuer":{"common_name":"R11"},"valid_from":"Sep  1 00:00:00 2026 GMT",' +
    '"valid_till":"Nov 30 00:00:00 2026 GMT","services":[{"display_name":' +
    '"DSM Desktop Service","service":"default","subscriber":"system",' +
    '"isPkg":false,"owner":"root"}]}]}';

func testCertificates() {
    def f as Fake init fake([
        ok(CERTS),
        ok('{"id":"New456","restart_httpd":true}'),
        ok("null"),
        ok("null"),
        ok(CERTS),
        ok("null"),
        ok(CERTS),
        ok(CERTS)
    ]);
    def c as Client init session($f);
    def all as list of Certificate init certificates($c);
    def pem as bytes init convert.bytesFromString("PEM", "utf-8");
    def none as bytes init convert.bytesFromString("", "utf-8");
    def id as string init importCertificate($c, $pem, $pem, $none, "ACME", "", true);
    setDefaultCertificate($c, $id);
    deleteCertificate($c, "Old789");
    assignCertificate($c, $id, "DSM Desktop Service");
    # Already in use: nothing to send.
    assignCertificate($c, "Abc123", "DSM Desktop Service");
    try {
        assignCertificate($c, "x", "FTPS");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "no certificate serves");
    }
    def seen as list of Seen init finish($f);
    testing.assertEqual(len($seen), 8);
    testing.assertEqual($all[0].commonName, "nas.example.com");
    testing.assertTrue($all[0].isDefault);
    testing.assertEqual($all[0].services, ["DSM Desktop Service"]);
    testing.assertEqual($id, "New456");
    testing.assertEqual($seen[1].query["method"], "import");
    testing.assertEqual($seen[1].query["_sid"], "sid-1");
    def parts as list of multipart.Part init multipart.parse($seen[1].contentType, $seen[1].body);
    testing.assertEqual(len($parts), 5);
    testing.assertEqual($parts[2].name, "as_default");
    testing.assertEqual($parts[3].name, "key");
    testing.assertEqual(formOf($seen[2], "id"), '"New456"');
    testing.assertEqual(formOf($seen[3], "ids"), '["Old789"]');
    testing.assertEqual(formOf($seen[5], "api"), "SYNO.Core.Certificate.Service");
    def settings as json.Value init json.decode(formOf($seen[5], "settings"));
    testing.assertEqual(json.asString($settings, "/0/old_id"), "Abc123");
    testing.assertEqual(json.asString($settings, "/0/id"), "New456");
    testing.assertEqual(json.asString($settings, "/0/service/service"), "default");
}

func testSnapshots() {
    def f as Fake init fake([
        ok('{"snapshots":[{"desc":"before upgrade","lock":true,"schedule_snapshot":false,' +
            '"time":"GMT+01-2026.11.04-12.00.00"}],"total":1}'),
        ok('"GMT+01-2026.11.04-13.00.00"'),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of Snapshot init snapshots($c, "backup");
    def made as string init createSnapshot($c, "backup", "nightly", false);
    deleteSnapshot($c, "backup", $made);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].name, "GMT+01-2026.11.04-12.00.00");
    testing.assertTrue($all[0].locked);
    testing.assertEqual($made, "GMT+01-2026.11.04-13.00.00");
    testing.assertEqual(formOf($seen[0], "version"), "2");
    testing.assertEqual(formOf($seen[1], "version"), "1");
    testing.assertEqual(formOf($seen[1], "snapinfo"), '{"desc":"nightly","lock":false}');
    testing.assertEqual(formOf($seen[2], "snapshots"), '["GMT+01-2026.11.04-13.00.00"]');
}

func testHealth() {
    def storage as string init '{"volumes":[{"id":"volume_1","vol_path":"/volume1",' +
        '"status":"normal","fs_type":"btrfs","size":{"total":"7999999999999",' +
        '"used":"1000000000000"}}],"disks":[{"id":"sata1","name":"Drive 1",' +
        '"model":"WD80EFZZ   ","status":"normal","smart_status":"normal","temp":36,' +
        '"size_total":"8001563222016"}]}';
    def f as Fake init fake([
        ok('{"cpu":{"user_load":7,"system_load":3,"other_load":1},"memory":{"real_usage":41,' +
            '"total_real":8000000,"avail_real":4700000},"network":[{"device":"total","rx":1200,' +
            '"tx":800},{"device":"eth0","rx":1200,"tx":800}]}'),
        ok($storage),
        ok($storage)
    ]);
    def c as Client init session($f);
    def u as Utilization init utilization($c);
    def vols as list of Volume init volumes($c);
    def drives as list of Disk init disks($c);
    def seen as list of Seen init finish($f);
    testing.assertEqual($u.cpuPercent, 11);
    testing.assertEqual($u.memoryPercent, 41);
    testing.assertEqual($u.rxBytes, 1200);
    testing.assertEqual($vols[0].path, "/volume1");
    testing.assertEqual($vols[0].usedBytes, 1000000000000);
    testing.assertEqual($drives[0].model, "WD80EFZZ");
    testing.assertEqual($drives[0].temperature, 36);
    testing.assertEqual(formOf($seen[1], "method"), "load_info");
}

func testSystem() {
    def f as Fake init fake([
        ok('{"update":{"available":true,"version":"DSM 7.2.2-72806 Update 3","reboot":"now"}}'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    def u as DsmUpdate init checkUpdate($c);
    reboot($c);
    shutdown($c);
    def seen as list of Seen init finish($f);
    testing.assertTrue($u.available);
    testing.assertEqual($u.reboot, "now");
    testing.assertEqual(formOf($seen[0], "version"), "4");
    testing.assertEqual(formOf($seen[1], "method"), "reboot");
    testing.assertEqual(formOf($seen[2], "api"), "SYNO.Core.System");
    testing.assertEqual(formOf($seen[2], "method"), "shutdown");
}

func testPackagesAndServices() {
    def f as Fake init fake([
        ok('{"packages":[{"id":"ContainerManager","name":"Container Manager",' +
            '"version":"24.0.2-1535","additional":{"status":"running"}}],"total":1}'),
        ok("null"),
        ok("null"),
        ok('{"enable_ssh":true,"ssh_port":22,"enable_telnet":false}'),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of Package init packages($c);
    stopPackage($c, "ContainerManager");
    startPackage($c, "ContainerManager");
    def ssh as bool init serviceEnabled($c, "ssh");
    setService($c, "smb", false);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].status, "running");
    testing.assertEqual(formOf($seen[0], "additional"), '["status"]');
    testing.assertEqual(formOf($seen[1], "method"), "stop");
    testing.assertEqual(formOf($seen[1], "id"), "ContainerManager");
    testing.assertTrue($ssh);
    testing.assertEqual(formOf($seen[3], "api"), "SYNO.Core.Terminal");
    testing.assertEqual(formOf($seen[4], "api"), "SYNO.Core.FileServ.SMB");
    testing.assertEqual(formOf($seen[4], "enable_samba"), "false");
    try {
        setService($c, "ftp", true);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a service is ssh, smb or nfs");
    }
}

func testScheduledTasks() {
    def f as Fake init fake([
        ok('{"tasks":[{"id":13,"name":"Sync folders","real_owner":"root","owner":"root",' +
            '"type":"script","enable":false,"next_trigger_time":"2026-11-05 03:00",' +
            '"action":"Run: rsync"}],"total":1}'),
        ok("null"),
        ok("null"),
        ok('[{"exit_code":0,"exit_type":"normal","start_time":"2026-11-04 03:00:01",' +
            '"stop_time":"2026-11-04 03:00:02","timestamp":"1793761201"}]')
    ]);
    def c as Client init session($f);
    def all as list of ScheduledTask init scheduledTasks($c);
    runScheduledTask($c, $all[0]);
    setScheduledTaskEnabled($c, $all[0], true);
    def runs as list of TaskResult init taskResults($c, $all[0]);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].id, 13);
    testing.assertEqual($all[0].owner, "root");
    testing.assertFalse($all[0].enabled);
    testing.assertEqual(formOf($seen[0], "version"), "3");
    testing.assertEqual(formOf($seen[1], "tasks"), '[{"id":13,"real_owner":"root"}]');
    testing.assertEqual(
        formOf($seen[2], "status"),
        '[{"id":13,"real_owner":"root","enable":true}]');
    testing.assertEqual($runs[0].exitType, "normal");
    testing.assertEqual(formOf($seen[3], "method"), "get_history_status_list");
}

func testHyperBackup() {
    def f as Fake init fake([
        ok('{"task_list":[{"task_id":3,"name":"Offsite","state":"backupable","status":"none"}]}'),
        ok('{"last_bkp_result":"done","last_bkp_time":"2026/11/04 02:00","next_bkp_time":' +
            '"2026/11/05 02:00","state":"backupable","status":"none"}'),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of BackupTask init backupTasks($c);
    def one as BackupTask init backupStatus($c, 3);
    runBackup($c, 3);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].name, "Offsite");
    testing.assertEqual($one.id, 3);
    testing.assertEqual($one.lastResult, "done");
    testing.assertEqual(formOf($seen[1], "task_id"), "3");
    testing.assertEqual(formOf($seen[2], "method"), "backup");
}

func testVersionsOutOfRange() {
    def f as Fake init fake([]);
    def c as Client init session($f);
    finish($f);
    $c.apis["SYNO.Core.TaskScheduler"].maxVersion = 2;
    try {
        scheduledTasks($c);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the deck needs 3");
    }
}

func testContainers() {
    def f as Fake init fake([
        ok('{"containers":[{"name":"caddy","id":"21bbe0c6","image":"caddy:alpine",' +
            '"status":"running"}],"total":1}'),
        ok('{"Config":{"Image":"caddy:alpine"},"State":{"Running":true}}'),
        ok("null"),
        ok("null"),
        ok("null"),
        ok("null"),
        ok('{"limit":2,"logs":[{"created":"2026-11-04T10:38:55Z","docid":"2","stream":"stderr",' +
            '"text":"serving on :80"},{"created":"2026-11-04T10:38:54Z","docid":"1",' +
            '"stream":"stdout","text":"starting"}],"offset":0,"total":2}')
    ]);
    def c as Client init session($f);
    def all as list of Container init containers($c);
    def details as json.Value init inspectContainer($c, "caddy");
    stopContainer($c, "caddy");
    startContainer($c, "caddy");
    restartContainer($c, "caddy");
    deleteContainer($c, "old-app", true);
    def lines as list of LogLine init containerLogs($c, "caddy", 2);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].image, "caddy:alpine");
    testing.assertEqual($all[0].status, "running");
    testing.assertTrue(json.asBool($details, "/State/Running"));
    testing.assertEqual(formOf($seen[0], "api"), "SYNO.Docker.Container");
    testing.assertEqual(formOf($seen[0], "type"), "all");
    testing.assertEqual(formOf($seen[2], "method"), "stop");
    testing.assertEqual(formOf($seen[4], "method"), "restart");
    testing.assertEqual(formOf($seen[5], "force"), "true");
    testing.assertEqual($lines[0].text, "serving on :80");
    testing.assertEqual($lines[0].stream, "stderr");
    testing.assertEqual(formOf($seen[6], "api"), "SYNO.Docker.Container.Log");
    testing.assertEqual(formOf($seen[6], "sort_dir"), "DESC");
    testing.assertEqual(formOf($seen[6], "limit"), "2");
    try {
        startContainer($c, "bad name");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a container name is letters");
    }
}

func testContainerImages() {
    def f as Fake init fake([
        ok('{"images":[{"created":1745034718,"id":"sha256:14300de7","repository":"caddy",' +
            '"size":50509416,"tags":["alpine"],"upgradable":false}],"limit":1,"offset":0,' +
            '"total":1}'),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of ContainerImage init containerImages($c);
    pullContainerImage($c, "ghcr.io/owner/app", "1.2.0");
    deleteContainerImage($c, "caddy", "alpine");
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].tags, ["alpine"]);
    testing.assertEqual($all[0].size, 50509416);
    testing.assertEqual(formOf($seen[1], "repository"), "ghcr.io/owner/app");
    testing.assertEqual(formOf($seen[1], "tag"), "1.2.0");
    testing.assertEqual(formOf($seen[2], "name"), "caddy");
    try {
        pullContainerImage($c, "Caddy", "latest");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "an image repository is lowercase");
    }
}

func testProjects() {
    def one as string init '{"containerIds":["21bbe0c6"],' +
        '"id":"187b2816-fd6c-4f87-b178-6d94806c7404",' +
        '"name":"web","path":"/volume1/docker/web","share_path":"/docker/web",' +
        '"status":"RUNNING"}';
    def f as Fake init fake([
        ok('{"187b2816-fd6c-4f87-b178-6d94806c7404":' + $one + '}'),
        ok($one),
        ok('{"id":"187b2816-fd6c-4f87-b178-6d94806c7404"}'),
        ok("null"),
        ok("null"),
        ok("null"),
        ok("null")
    ]);
    def c as Client init session($f);
    def all as list of Project init projects($c);
    def id as string init "187b2816-fd6c-4f87-b178-6d94806c7404";
    def got as Project init project($c, $id);
    def yaml as string init "services:\n  web:\n    image: caddy:alpine\n";
    testing.assertEqual(createProject($c, "web", "/docker/web", $yaml), $id);
    buildProject($c, $id);
    stopProject($c, $id);
    startProject($c, $id);
    deleteProject($c, $id, true);
    def seen as list of Seen init finish($f);
    testing.assertEqual($all[0].name, "web");
    testing.assertEqual($all[0].path, "/docker/web");
    testing.assertEqual($got.containerIds, ["21bbe0c6"]);
    testing.assertEqual(formOf($seen[2], "method"), "create");
    testing.assertEqual(formOf($seen[2], "share_path"), "/docker/web");
    testing.assertEqual(formOf($seen[2], "content"), $yaml);
    testing.assertEqual(formOf($seen[2], "enable_service_portal"), "false");
    testing.assertEqual(formOf($seen[3], "method"), "build");
    testing.assertEqual(formOf($seen[6], "preserve_content"), "true");
    try {
        createProject($c, "Web App", "/docker/web", $yaml);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a project name is lowercase");
    }
    try {
        stopProject($c, "../x");
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "a project id is a UUID");
    }
}

func testVmTaskWithoutResult() {
    def f as Fake init fake([
        ok('{"task_id":"t1"}'),
        ok('{"finish":true,"task_info":{"progress":100,"status":"error"}}'),
        ok('{"task_id":"t2"}'),
        ok('{"finish":true,"task_info":{"status":"error"}}')
    ]);
    def c as Client init session($f);
    def spec as GuestSpec init GuestSpec{
        name: "web01",
        storage: "s",
        disks: [DiskSpec{sizeMb: 1024, image: ""}],
        networks: [],
        vcpus: 0,
        ramMb: 0
    };
    try {
        createGuest($c, $spec);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the task ended without a virtual machine");
    }
    try {
        createImage($c, "x", "iso", "/vm/x.iso", ["s"]);
        missed();
    } catch (e) {
        testing.assertContains(messageOf($e), "the task ended without an image");
    }
    finish($f);
}

func testProjectsSortByName() {
    def f as Fake init fake([
        ok('{"0aaa":{"id":"0aaa","name":"zeta","status":"RUNNING"},' +
            '"ffff":{"id":"ffff","name":"alpha","status":"STOPPED"}}')
    ]);
    def all as list of Project init projects(session($f));
    finish($f);
    testing.assertEqual($all[0].name, "alpha");
    testing.assertEqual($all[1].name, "zeta");
}
