"""Test-only stand-in for Supabase: serves site/ and answers POST /rest/v1/rpc/<fn> by calling
the function in Postgres as the 'anon' role, the way PostgREST does."""
import json, sys, os
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import psycopg
from psycopg.types.json import Jsonb

DSN = "host=/var/tmp port=54329 user=postgres dbname=bk"
SITE = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8099


def sig(conn, fn):
    row = conn.execute("""select p.proargnames, array(select format_type(t, null) from unnest(p.proargtypes) t)
                          from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=%s""", (fn,)).fetchone()
    return (row[0] or [], row[1]) if row else None


class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=SITE, **k)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/config.js"):
            body = ('window.BREWSKIS_CONFIG={supabaseUrl:location.origin,supabaseAnonKey:"test-anon",vapidPublicKey:"%s"};' % os.environ.get("VAPID_PUBLIC","")).encode()
            self.send_response(200); self.send_header("Content-Type", "application/javascript"); self.end_headers(); self.wfile.write(body); return
        return super().do_GET()

    def do_POST(self):
        if self.path.startswith("/functions/v1/notify"):
            import urllib.request
            data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            req = urllib.request.Request("http://127.0.0.1:8000/", data=data, method="POST", headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as r: code, out = r.status, r.read()
            except urllib.error.HTTPError as e: code, out = e.code, e.read()
            self.send_response(code); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(out); return
        if not self.path.startswith("/rest/v1/rpc/"):
            self.send_response(404); self.end_headers(); return
        fn = self.path.rsplit("/", 1)[1]
        args = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        try:
            with psycopg.connect(DSN, autocommit=True) as conn:
                s = sig(conn, fn)
                if not s or not fn.startswith("api_"):
                    raise psycopg.errors.UndefinedFunction("not found")
                names, types = s
                parts, vals = [], []
                for n, t in zip(names, types):
                    if n in args:
                        v = args[n]
                        if t in ("jsonb", "json"): v = Jsonb(v)
                        parts.append(f"{n} => %s::{t}"); vals.append(v)
                with conn.transaction():
                    conn.execute("set local role anon")
                    row = conn.execute(f"select to_json({fn}({', '.join(parts)}))", vals).fetchone()
            out = json.dumps(row[0]).encode() if row and row[0] is not None else b""
            self.send_response(200)
        except psycopg.Error as e:
            out = json.dumps({"code": e.sqlstate, "message": (e.diag.message_primary if e.diag else str(e))}).encode()
            self.send_response(400)
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out)


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
