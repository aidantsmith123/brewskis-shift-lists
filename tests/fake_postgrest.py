"""Test-only stand-in for Supabase: serves site/ and answers POST /rest/v1/rpc/<fn> by calling
the function in Postgres as the 'anon' role, the way PostgREST does. It also stands in for Supabase Realtime:
a websocket at /realtime/v1/websocket speaking the same Phoenix protocol (version 1.0.0), passing on what the
database's realtime.send stand-in (tests/fixtures/realtime_stub.sql) sends through NOTIFY."""
import json, sys, os, base64, hashlib, struct, threading
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


# ---------- the Realtime stand-in ----------
CLIENTS = []            # [handler, joined topics, send lock]
CLIENTS_LOCK = threading.Lock()
STATS = {"joins": 0, "sent": 0}


def ws_send(c, obj):
    data = json.dumps(obj).encode()
    n = len(data)
    head = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n))
    with c[2]:
        c[0].wfile.write(head + data); c[0].wfile.flush()


def ws_recv(rf):
    b = rf.read(2)
    if len(b) < 2: return None, None
    op, n = b[0] & 0x0F, b[1] & 0x7F
    if n == 126: n = struct.unpack(">H", rf.read(2))[0]
    elif n == 127: n = struct.unpack(">Q", rf.read(8))[0]
    mask = rf.read(4) if b[1] & 0x80 else b"\0\0\0\0"
    data = bytes(x ^ mask[i % 4] for i, x in enumerate(rf.read(n)))
    return op, data


def listen():
    import time
    while True:   # the test database gets rebuilt between suites, so keep reconnecting
        try:
            conn = psycopg.connect(DSN, autocommit=True)
            conn.execute("listen realtime")
            for n in conn.notifies(): relay(n)
        except Exception:
            time.sleep(0.5)


def relay(n):
    m = json.loads(n.payload)
    topic = "realtime:" + m["topic"]
    with CLIENTS_LOCK: targets = [c for c in CLIENTS if topic in c[1]]
    for c in targets:
        try:
            ws_send(c, {"topic": topic, "event": "broadcast", "ref": None, "join_ref": None,
                        "payload": {"type": "broadcast", "event": m["event"], "payload": m["payload"]}})
            STATS["sent"] += 1
        except Exception:
            pass


class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=SITE, **k)

    def log_message(self, *a):
        pass

    def websocket(self):
        if os.environ.get("NO_REALTIME"):
            self.send_response(503); self.end_headers(); return
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept); self.end_headers(); self.wfile.flush()
        c = [self, set(), threading.Lock()]
        with CLIENTS_LOCK: CLIENTS.append(c)
        try:
            while True:
                op, data = ws_recv(self.rfile)
                if op is None or op == 0x8: break
                if op == 0x9: continue
                m = json.loads(data)
                if m["event"] == "phx_join":
                    c[1].add(m["topic"]); STATS["joins"] += 1
                if m["event"] == "phx_leave": c[1].discard(m["topic"])
                ws_send(c, {"topic": m["topic"], "event": "phx_reply", "ref": m.get("ref"), "join_ref": m.get("join_ref"),
                            "payload": {"status": "ok", "response": {"postgres_changes": []} if m["event"] == "phx_join" else {}}})
        except Exception:
            pass
        finally:
            with CLIENTS_LOCK:
                if c in CLIENTS: CLIENTS.remove(c)
            self.close_connection = True

    def do_GET(self):
        if self.path.startswith("/realtime/v1/websocket") and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        if self.path.startswith("/__live"):   # for the tests: who's connected, and drop everyone (as if the network blipped)
            if "drop" in self.path:
                with CLIENTS_LOCK: cs = list(CLIENTS)
                for c in cs:
                    try: c[0].connection.shutdown(2)
                    except Exception: pass
            with CLIENTS_LOCK: body = json.dumps({"clients": len(CLIENTS), "joined": sum(1 for c in CLIENTS if c[1]), **STATS}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
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


threading.Thread(target=listen, daemon=True).start()
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
