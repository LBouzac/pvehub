#!/usr/bin/env python3
"""PVE Hub — petite interface Proxmox + chat Hermes.

Aucune dépendance : uniquement la bibliothèque standard Python 3.9+.
Configuration via variables d'environnement ou fichier .env à côté du script.
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(BASE, "static")


def load_env(path):
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


load_env(os.environ.get("PVEHUB_ENV", os.path.join(BASE, ".env")))

PVE_URL = os.environ.get("PVE_URL", "").rstrip("/")          # https://192.168.1.10:8006
PVE_TOKEN = os.environ.get("PVE_TOKEN", "")                   # user@realm!id=secret
PVE_VERIFY = os.environ.get("PVE_VERIFY_SSL", "false").lower() == "true"
HERMES_URL = os.environ.get("HERMES_URL", "").rstrip("/")     # http://192.168.1.20:8642
HERMES_KEY = os.environ.get("HERMES_KEY", "")
HERMES_MODEL = os.environ.get("HERMES_MODEL", "hermes-agent")
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")
APP_SECRET = (os.environ.get("APP_SECRET") or secrets.token_hex(32)).encode()
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
SESSION_DAYS = 30

if not PVE_URL or not PVE_TOKEN:
    sys.exit("PVE_URL et PVE_TOKEN sont obligatoires (voir .env).")

PVE_CTX = ssl.create_default_context()
if not PVE_VERIFY:
    PVE_CTX.check_hostname = False
    PVE_CTX.verify_mode = ssl.CERT_NONE

RE_NODE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
RE_SNAP = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,39}$")
RE_STORE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
RE_UPID = re.compile(r"^UPID:[A-Za-z0-9:._@!-]+$")
POWER = {"start", "shutdown", "stop", "reboot"}


class ApiError(Exception):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status
        self.msg = msg


# ---------------------------------------------------------------- Proxmox

def pve(method, path, params=None, timeout=30):
    url = f"{PVE_URL}/api2/json{path}"
    params = {k: v for k, v in (params or {}).items() if v is not None}
    data = None
    if method == "GET":
        if params:
            url += "?" + urllib.parse.urlencode(params)
    else:
        data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"PVEAPIToken={PVE_TOKEN}")
    if data is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, context=PVE_CTX, timeout=timeout) as r:
            return json.loads(r.read() or b"{}").get("data")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            j = json.loads(body)
            detail = j.get("message") or json.dumps(j.get("errors") or "")
        except ValueError:
            detail = body[:200]
        raise ApiError(502 if e.code >= 500 else e.code if e.code != 401 else 502,
                       f"Proxmox : {e.reason} {detail}".strip())
    except (urllib.error.URLError, OSError) as e:
        raise ApiError(502, f"Proxmox injoignable : {getattr(e, 'reason', e)}")


def guest_args(d):
    node, typ, vmid = d.get("node", ""), d.get("type", ""), d.get("vmid")
    if not RE_NODE.match(str(node)):
        raise ApiError(400, "Nœud invalide")
    if typ not in ("qemu", "lxc"):
        raise ApiError(400, "Type invalide")
    try:
        vmid = int(vmid)
    except (TypeError, ValueError):
        raise ApiError(400, "VMID invalide")
    if not 100 <= vmid <= 999999999:
        raise ApiError(400, "VMID invalide")
    return node, typ, vmid


def fmt_bytes(n):
    n = float(n or 0)
    for unit in ("o", "Ko", "Mo", "Go", "To"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit in ("o", "Ko") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} Po"


def fmt_uptime(s):
    s = int(s or 0)
    d, h = s // 86400, (s % 86400) // 3600
    return f"{d} j {h} h" if d else f"{h} h {(s % 3600) // 60} min"


def cluster_summary():
    nodes = pve("GET", "/nodes") or []
    guests = pve("GET", "/cluster/resources", {"type": "vm"}) or []
    lines = []
    for n in nodes:
        lines.append(
            f"Nœud {n.get('node')} : {n.get('status')}, CPU {100 * (n.get('cpu') or 0):.0f} % "
            f"({n.get('maxcpu')} cœurs), RAM {fmt_bytes(n.get('mem'))}/{fmt_bytes(n.get('maxmem'))}, "
            f"en ligne depuis {fmt_uptime(n.get('uptime'))}")
    for g in sorted(guests, key=lambda x: x.get("vmid", 0)):
        if g.get("template"):
            continue
        kind = "VM" if g.get("type") == "qemu" else "CT"
        line = (f"- {kind} {g.get('vmid')} « {g.get('name', '')} » (type={g.get('type')}, nœud={g.get('node')}) : "
                f"{g.get('status')}")
        if g.get("status") == "running":
            line += (f", CPU {100 * (g.get('cpu') or 0):.0f} %, RAM {fmt_bytes(g.get('mem'))}/"
                     f"{fmt_bytes(g.get('maxmem'))}, disque {fmt_bytes(g.get('disk'))}/{fmt_bytes(g.get('maxdisk'))}")
        lines.append(line)
    return "\n".join(lines)


SYSTEM_PROMPT = """Tu es intégré à « PVE Hub », l'application avec laquelle l'utilisateur gère son serveur Proxmox depuis son téléphone. Réponds en français, de façon concise (écran de téléphone).

État du serveur au moment de ce message ({now}) :
{summary}

Tu peux proposer des actions que l'utilisateur exécutera d'un tap, après confirmation. Pour cela, ajoute un bloc par action, exactement sous cette forme :
```pvehub
{{"action": "reboot", "node": "pve", "type": "lxc", "vmid": 101}}
```
Actions possibles : start, shutdown (arrêt propre), stop (arrêt forcé), reboot, snapshot (champ "name" obligatoire : lettres, chiffres, - ou _, commence par une lettre ; "description" facultatif), rollback ("name" du snapshot), backup ("storage" et "mode" facultatifs : snapshot|suspend|stop).
"type" vaut "qemu" pour une VM et "lxc" pour un conteneur. N'exécute pas toi-même ces opérations Proxmox par le terminal : propose-les avec ces blocs, l'application s'en charge. Les messages commençant par [PVE Hub] décrivent des actions déjà exécutées par l'utilisateur."""


# ---------------------------------------------------------------- Auth

def make_session():
    exp = str(int(time.time()) + SESSION_DAYS * 86400)
    sig = hmac.new(APP_SECRET, exp.encode(), hashlib.sha256).hexdigest()
    return f"{exp}.{sig}"


def valid_session(value):
    try:
        exp, sig = value.split(".", 1)
        good = hmac.new(APP_SECRET, exp.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, good) and int(exp) > time.time()
    except (ValueError, AttributeError):
        return False


# ---------------------------------------------------------------- HTTP

MIME = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css",
        ".svg": "image/svg+xml", ".webmanifest": "application/manifest+json", ".png": "image/png"}


class Handler(BaseHTTPRequestHandler):
    server_version = "PVEHub/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("DEBUG"):
            super().log_message(fmt, *args)

    # -- helpers
    def send_json(self, obj, status=200, extra=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 1_000_000:
            raise ApiError(413, "Requête trop grande")
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except ValueError:
            raise ApiError(400, "JSON invalide")

    def authed(self):
        if not APP_PASSWORD:
            return True
        c = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        return "pvehub" in c and valid_session(c["pvehub"].value)

    def qs(self):
        return {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).items()}

    def serve_static(self, rel):
        rel = rel.lstrip("/") or "index.html"
        full = os.path.realpath(os.path.join(STATIC, rel))
        if not full.startswith(os.path.realpath(STATIC) + os.sep) or not os.path.isfile(full):
            full, rel = os.path.join(STATIC, "index.html"), "index.html"
        with open(full, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(os.path.splitext(full)[1], "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    # -- dispatch
    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def dispatch(self, method):
        path = urllib.parse.urlsplit(self.path).path
        try:
            if not path.startswith("/api/"):
                if method != "GET":
                    raise ApiError(405, "Méthode non autorisée")
                return self.serve_static(path)
            if path == "/api/login" and method == "POST":
                return self.login()
            if path == "/api/logout" and method == "POST":
                return self.send_json({"ok": True}, extra={
                    "Set-Cookie": "pvehub=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"})
            if not self.authed():
                raise ApiError(401, "Non connecté")
            route = ROUTES.get((method, path))
            if not route:
                raise ApiError(404, "Route inconnue")
            if path == "/api/chat":
                return route(self)
            data = self.qs() if method == "GET" else self.body()
            self.send_json(route(data))
        except ApiError as e:
            self.send_json({"error": e.msg}, e.status)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # noqa: BLE001
            print("Erreur :", repr(e), file=sys.stderr)
            try:
                self.send_json({"error": "Erreur interne"}, 500)
            except OSError:
                pass

    def login(self):
        d = self.body()
        if not APP_PASSWORD or hmac.compare_digest(str(d.get("password", "")), APP_PASSWORD):
            return self.send_json({"ok": True}, extra={
                "Set-Cookie": f"pvehub={make_session()}; Path=/; Max-Age={SESSION_DAYS * 86400}; HttpOnly; SameSite=Strict"})
        time.sleep(1.5)
        raise ApiError(403, "Mot de passe incorrect")

    # -- chat (stream SSE)
    def chat(self):
        if not HERMES_URL:
            raise ApiError(503, "Hermes n'est pas configuré (HERMES_URL)")
        d = self.body()
        msgs = []
        for m in (d.get("messages") or [])[-40:]:
            if m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str):
                msgs.append({"role": m["role"], "content": m["content"][:20000]})
        if not msgs:
            raise ApiError(400, "Message vide")
        try:
            summary = cluster_summary()
        except ApiError as e:
            summary = f"(état indisponible : {e.msg})"
        system = SYSTEM_PROMPT.format(now=time.strftime("%d/%m/%Y %H:%M"), summary=summary)
        payload = json.dumps({"model": HERMES_MODEL, "stream": True,
                              "messages": [{"role": "system", "content": system}] + msgs}).encode()
        req = urllib.request.Request(f"{HERMES_URL}/v1/chat/completions", data=payload, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {HERMES_KEY}")
        req.add_header("Accept", "text/event-stream")
        try:
            upstream = urllib.request.urlopen(req, timeout=900)
        except urllib.error.HTTPError as e:
            raise ApiError(502, f"Hermes : {e.code} {e.read().decode(errors='replace')[:200]}")
        except (urllib.error.URLError, OSError) as e:
            raise ApiError(502, f"Hermes injoignable : {getattr(e, 'reason', e)}")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        with upstream:
            try:
                for line in upstream:
                    self.wfile.write(line)
                    if line in (b"\n", b"\r\n"):
                        self.wfile.flush()
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass


# ---------------------------------------------------------------- routes

def r_overview(_):
    nodes = pve("GET", "/nodes") or []
    guests = pve("GET", "/cluster/resources", {"type": "vm"}) or []
    storage = pve("GET", "/cluster/resources", {"type": "storage"}) or []
    return {"nodes": nodes, "guests": guests, "storage": storage, "hermes": bool(HERMES_URL)}


def r_rrd(q):
    tf = q.get("tf", "hour")
    if tf not in ("hour", "day", "week"):
        tf = "hour"
    if q.get("type"):
        node, typ, vmid = guest_args(q)
        path = f"/nodes/{node}/{typ}/{vmid}/rrddata"
    else:
        if not RE_NODE.match(q.get("node", "")):
            raise ApiError(400, "Nœud invalide")
        path = f"/nodes/{q['node']}/rrddata"
    return {"data": pve("GET", path, {"timeframe": tf, "cf": "AVERAGE"}) or []}


def r_guest(q):
    node, typ, vmid = guest_args(q)
    status = pve("GET", f"/nodes/{node}/{typ}/{vmid}/status/current") or {}
    config = pve("GET", f"/nodes/{node}/{typ}/{vmid}/config") or {}
    keep = ("cores", "sockets", "memory", "swap", "ostype", "description", "onboot", "hostname",
            "rootfs", "scsi0", "virtio0", "sata0", "net0", "boot")
    return {"status": status, "config": {k: config[k] for k in keep if k in config}}


def r_power(d):
    node, typ, vmid = guest_args(d)
    action = d.get("action")
    if action not in POWER:
        raise ApiError(400, "Action invalide")
    return {"upid": pve("POST", f"/nodes/{node}/{typ}/{vmid}/status/{action}"), "node": node}


def r_snapshots(q):
    node, typ, vmid = guest_args(q)
    snaps = pve("GET", f"/nodes/{node}/{typ}/{vmid}/snapshot") or []
    return {"items": sorted([s for s in snaps if s.get("name") != "current"],
                            key=lambda s: s.get("snaptime", 0), reverse=True)}


def snap_name(d):
    name = str(d.get("name", ""))
    if not RE_SNAP.match(name):
        raise ApiError(400, "Nom de snapshot invalide (lettres, chiffres, - ou _, commence par une lettre)")
    return name


def r_snap_create(d):
    node, typ, vmid = guest_args(d)
    params = {"snapname": snap_name(d), "description": str(d.get("description") or "")[:500] or None}
    if typ == "qemu" and d.get("vmstate"):
        params["vmstate"] = 1
    return {"upid": pve("POST", f"/nodes/{node}/{typ}/{vmid}/snapshot", params), "node": node}


def r_snap_rollback(d):
    node, typ, vmid = guest_args(d)
    return {"upid": pve("POST", f"/nodes/{node}/{typ}/{vmid}/snapshot/{snap_name(d)}/rollback"), "node": node}


def r_snap_delete(d):
    node, typ, vmid = guest_args(d)
    return {"upid": pve("DELETE", f"/nodes/{node}/{typ}/{vmid}/snapshot/{snap_name(d)}"), "node": node}


def backup_storages(node):
    stores = pve("GET", f"/nodes/{node}/storage", {"content": "backup", "enabled": 1}) or []
    return [s["storage"] for s in stores if s.get("active", 1)]


def r_backups(q):
    node, _typ, vmid = guest_args(q)
    stores = backup_storages(node)
    items = []
    for s in stores:
        try:
            for it in pve("GET", f"/nodes/{node}/storage/{s}/content", {"content": "backup", "vmid": vmid}) or []:
                it["storage"] = s
                items.append(it)
        except ApiError:
            continue
    items.sort(key=lambda i: i.get("ctime", 0), reverse=True)
    return {"storages": stores, "items": items}


def r_backup(d):
    node, _typ, vmid = guest_args(d)
    storage = d.get("storage") or (backup_storages(node) or [None])[0]
    if not storage or not RE_STORE.match(storage):
        raise ApiError(400, "Aucun stockage de sauvegarde disponible")
    mode = d.get("mode") or "snapshot"
    if mode not in ("snapshot", "suspend", "stop"):
        raise ApiError(400, "Mode invalide")
    upid = pve("POST", f"/nodes/{node}/vzdump",
               {"vmid": vmid, "storage": storage, "mode": mode, "compress": "zstd",
                "notes-template": "{{guestname}} — PVE Hub"})
    return {"upid": upid, "node": node}


def r_restore(d):
    node, typ, vmid = guest_args(d)
    volid = str(d.get("volid", ""))
    if not re.match(r"^[A-Za-z0-9_.-]+:[A-Za-z0-9_./-]+$", volid) or f"-{vmid}-" not in volid:
        raise ApiError(400, "Sauvegarde invalide pour cette machine")
    status = (pve("GET", f"/nodes/{node}/{typ}/{vmid}/status/current") or {}).get("status")
    if status != "stopped":
        raise ApiError(409, "Arrête la machine avant de restaurer")
    if typ == "qemu":
        upid = pve("POST", f"/nodes/{node}/qemu", {"vmid": vmid, "archive": volid, "force": 1})
    else:
        cfg = pve("GET", f"/nodes/{node}/lxc/{vmid}/config") or {}
        storage = str(cfg.get("rootfs", "")).split(":", 1)[0] or None
        upid = pve("POST", f"/nodes/{node}/lxc",
                   {"vmid": vmid, "ostemplate": volid, "restore": 1, "force": 1, "storage": storage})
    return {"upid": upid, "node": node}


def r_task(q):
    node, upid = q.get("node", ""), q.get("upid", "")
    if not RE_NODE.match(node) or not RE_UPID.match(upid):
        raise ApiError(400, "Tâche invalide")
    return pve("GET", f"/nodes/{node}/tasks/{urllib.parse.quote(upid, safe='')}/status") or {}


def r_tasks(q):
    if not RE_NODE.match(q.get("node", "")):
        raise ApiError(400, "Nœud invalide")
    return {"items": pve("GET", f"/nodes/{q['node']}/tasks", {"limit": 20}) or []}


ROUTES = {
    ("GET", "/api/overview"): r_overview,
    ("GET", "/api/rrd"): r_rrd,
    ("GET", "/api/guest"): r_guest,
    ("POST", "/api/power"): r_power,
    ("GET", "/api/snapshots"): r_snapshots,
    ("POST", "/api/snapshot"): r_snap_create,
    ("POST", "/api/snapshot/rollback"): r_snap_rollback,
    ("POST", "/api/snapshot/delete"): r_snap_delete,
    ("GET", "/api/backups"): r_backups,
    ("POST", "/api/backup"): r_backup,
    ("POST", "/api/restore"): r_restore,
    ("GET", "/api/task"): r_task,
    ("GET", "/api/tasks"): r_tasks,
    ("POST", "/api/chat"): Handler.chat,
}


if __name__ == "__main__":
    if not APP_PASSWORD:
        print("⚠️  APP_PASSWORD vide : l'interface est accessible sans mot de passe.", file=sys.stderr)
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print(f"PVE Hub sur http://{HOST}:{PORT} → {PVE_URL}" + (f" | Hermes {HERMES_URL}" if HERMES_URL else ""))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
