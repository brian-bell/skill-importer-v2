"""§5 import url. Runs the binary against an in-process HTTP server serving
crafted bodies, exercising the 1 MiB cap / UTF-8 / fetch-failure rules. N/A if
the server can't be started. 5.3 (unreachable) and 5.6 (missing flag) always run.
"""

import http.server
import os
import threading
from pathlib import Path

GOOD_MD = b"---\nname: url-skill\ndescription: from a url\n---\n# body\n"
BAD_NAME_MD = b"---\nname: a/b\ndescription: d\n---\n"
NON_UTF8 = b"---\nname: u\ndescription: d\n---\n\xff\xfe not utf8\n"
# Cap is 1<<20 and the accept boundary is `> max_body_bytes`, so a body of
# exactly 1 MiB passes; overshoot by 1 KiB to unambiguously trip size_exceeded.
BIG = b"---\nname: big\ndescription: d\n---\n" + b"x" * (1024 * 1024 + 1024)

ROUTES = {
    "/good.md": ("text/markdown; charset=utf-8", GOOD_MD),
    "/badname.md": ("text/markdown; charset=utf-8", BAD_NAME_MD),
    "/nonutf8.md": ("text/markdown; charset=utf-8", NON_UTF8),
    "/big.md": ("text/markdown; charset=utf-8", BIG),
}


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        route = ROUTES.get(self.path)
        if route is None:
            self.send_response(404)
            self.end_headers()
            return
        ctype, body = route
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # silence
        pass


def _start_server():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


def run(cli, sb, rep, enabled=None):
    # enabled: True forces, False skips, None = auto (try to start the server).
    srv = None
    if enabled is not False:
        try:
            srv = _start_server()
        except Exception:  # noqa: BLE001
            srv = None

    base = None
    if srv is not None:
        host, port = srv.server_address
        base = "http://127.0.0.1:{}".format(port)

    def url(p):
        return base + p

    try:
        sb.reset()
        with rep.case("5.1", "url happy fetch") as c:
            if base is None:
                c.na("could not start in-process HTTP server")
            else:
                r = cli.si("--format", "json", "import", "url", "--url", url("/good.md"))
                c.exit(r, 0)
                c.json(r, lambda o: (
                    o["manifest"]["source_type"] == "url"
                    and o["manifest"]["source_location"] == url("/good.md")
                ))

        sb.reset()
        with rep.case("5.2", "bad name in fetched body") as c:
            if base is None:
                c.na("no server")
            else:
                r = cli.si("import", "url", "--url", url("/badname.md"))
                c.exit(r, 1)
                c.stderr_has(r, "not a single directory-safe path segment")
                if os.listdir(sb.imports):
                    c.fail("no storage expected")

        sb.reset()
        with rep.case("5.3", "unreachable host -> fetch failed") as c:
            # Port 1 on loopback: connection refused. Always runnable.
            r = cli.si("import", "url", "--url", "http://127.0.0.1:1/nope.md")
            c.exit(r, 1)
            c.stderr_has(r, "failed to fetch the URL")

        sb.reset()
        with rep.case("5.4", "non-UTF-8 body rejected") as c:
            if base is None:
                c.na("no server")
            else:
                r = cli.si("import", "url", "--url", url("/nonutf8.md"))
                c.exit(r, 1)
                c.stderr_has(r, "not valid UTF-8")
                if os.listdir(sb.imports):
                    c.fail("no storage expected")

        sb.reset()
        with rep.case("5.5", "body over 1 MiB rejected") as c:
            if base is None:
                c.na("no server")
            else:
                r = cli.si("import", "url", "--url", url("/big.md"))
                c.exit(r, 1)
                c.stderr_has(r, "exceeded the maximum allowed size")

        sb.reset()
        with rep.case("5.6", "missing --url") as c:
            r = cli.si("import", "url")
            c.exit(r, 1)
            c.stderr_has(r, "import url requires --url")
    finally:
        if srv is not None:
            srv.shutdown()
