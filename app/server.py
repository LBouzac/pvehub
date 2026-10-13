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
import shlex
import ssl
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
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
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")
APP_SECRET = (os.environ.get("APP_SECRET") or secrets.token_hex(32)).encode()
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
SESSION_DAYS = 30
# Commandes : SSH root vers l'hôte avec la clé posée par l'installeur (absente = section désactivée)
SSH_DIR = os.environ.get("SSH_DIR", os.path.join(BASE, "ssh"))
SSH_KEY = os.path.join(SSH_DIR, "id_ed25519")
EXEC_ENABLED = os.path.isfile(SSH_KEY) and os.environ.get("EXEC_ENABLED", "true").lower() != "false"
UPDATE_REPO = os.environ.get("UPDATE_REPO", "LBouzac/pvehub")  # dépôt GitHub d'où viennent les mises à jour
DATA_DIR = os.environ.get("DATA_DIR", os.path.join(BASE, "data"))
APPS_FILE = os.path.join(DATA_DIR, "apps.json")

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
RE_RUN = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
POWER = {"start", "shutdown", "stop", "reboot"}
APPROVAL_CHOICES = {"once", "session", "always", "deny"}


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


def hermes(method, path, body=None, stream=False):
    if not HERMES_URL:
        raise ApiError(503, "Hermes n'est pas configuré (HERMES_URL)")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{HERMES_URL}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {HERMES_KEY}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if stream:
        req.add_header("Accept", "text/event-stream")
    try:
        r = urllib.request.urlopen(req, timeout=900 if stream else 30)
    except urllib.error.HTTPError as e:
        raise ApiError(502, f"Hermes : {e.code} {e.read().decode(errors='replace')[:200]}")
    except (urllib.error.URLError, OSError) as e:
        raise ApiError(502, f"Hermes injoignable : {getattr(e, 'reason', e)}")
    if stream:
        return r
    with r:
        return json.loads(r.read() or b"{}")


def run_ssh(remote, timeout=60):
    host = urllib.parse.urlsplit(PVE_URL).hostname
    cmd = ["ssh", "-i", SSH_KEY, "-o", f"UserKnownHostsFile={SSH_DIR}/known_hosts",
           "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "LogLevel=ERROR", f"root@{host}", remote]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, f"(délai dépassé : {timeout} s)"
    out = (p.stdout + p.stderr).decode(errors="replace")
    return p.returncode, out[-60000:]


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
        if msgs[-1]["role"] != "user":
            raise ApiError(400, "Le dernier message doit venir de toi")
        system = SYSTEM_PROMPT.format(now=time.strftime("%d/%m/%Y %H:%M"), summary=summary)
        # API « runs » : seule à exposer les demandes d'autorisation de Hermes (approval.request)
        run = hermes("POST", "/v1/runs", {"input": msgs[-1]["content"], "instructions": system,
                                           "conversation_history": msgs[:-1]})
        run_id = str(run.get("run_id", ""))
        if not RE_RUN.match(run_id):
            raise ApiError(502, "Hermes : réponse inattendue")
        upstream = hermes("GET", f"/v1/runs/{run_id}/events", stream=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        with upstream:
            try:
                self.wfile.write(f'data: {{"event": "pvehub.run", "run_id": "{run_id}"}}\n\n'.encode())
                self.wfile.flush()
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
    return {"nodes": nodes, "guests": guests, "storage": storage, "hermes": bool(HERMES_URL), "exec": EXEC_ENABLED}


def r_exec(d):
    if not EXEC_ENABLED:
        raise ApiError(403, "Commandes désactivées (relance l'installeur pour les activer)")
    command = str(d.get("command", "")).strip()
    if not command or len(command) > 4000:
        raise ApiError(400, "Commande vide ou trop longue")
    t0 = time.time()
    if d.get("type") in (None, "", "host"):
        code, out = run_ssh(f"bash -lc {shlex.quote(command)}")
    else:
        # shortcut: SSH vers l'hôte de PVE_URL uniquement, les machines d'un autre nœud échouent ; passer par le nœud de la machine si cluster
        _node, typ, vmid = guest_args(d)
        if typ == "lxc":
            code, out = run_ssh(f"pct exec {vmid} -- sh -c {shlex.quote(command)}")
        else:
            code, out = run_ssh(f"qm guest exec {vmid} --timeout 55 -- sh -c {shlex.quote(command)}")
            try:  # qm renvoie du JSON : on extrait la vraie sortie de la VM
                j = json.loads(out)
                code = j.get("exitcode", code)
                out = (j.get("out-data", "") + j.get("err-data", "")) or out
            except ValueError:
                if "agent" in out.lower():
                    out += "\n(Agent QEMU absent ou arrêté dans la VM : installe qemu-guest-agent.)"
    return {"code": code, "output": out, "ms": int((time.time() - t0) * 1000)}


def r_approval(d):
    run_id, choice = str(d.get("run_id", "")), d.get("choice")
    if not RE_RUN.match(run_id) or choice not in APPROVAL_CHOICES:
        raise ApiError(400, "Demande invalide")
    body = {"choice": choice}
    if isinstance(d.get("request_id"), str) and RE_RUN.match(d["request_id"]):
        body["request_id"] = d["request_id"]
    return hermes("POST", f"/v1/runs/{run_id}/approval", body)


# ---------------------------------------------------------------- mise à jour
_upd = {"at": 0, "data": None}


def read_local(name):
    try:
        with open(os.path.join(BASE, name), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def github(url):
    req = urllib.request.Request(url, headers={"User-Agent": "PVEHub", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode()


def r_version(q):
    local, ctid = read_local("VERSION"), read_local("CTID")
    if q.get("check") or _upd["data"] is None or time.time() - _upd["at"] > 3600:
        try:
            # dernier commit exact puis VERSION à ce commit : évite le cache de 5 min de raw.githubusercontent.com
            sha = json.loads(github(f"https://api.github.com/repos/{UPDATE_REPO}/commits/main"))["sha"]
            remote = github(f"https://raw.githubusercontent.com/{UPDATE_REPO}/{sha}/VERSION").strip()
            _upd["data"] = {"remote": remote, "sha": sha, "error": None}
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            _upd["data"] = {"remote": None, "sha": None, "error": f"GitHub injoignable : {getattr(e, 'reason', e)}"}
        _upd["at"] = time.time()
    d = _upd["data"]
    return {"local": local or None, "remote": d["remote"], "error": d["error"],
            "available": bool(d["remote"] and d["remote"] != local),
            "can_update": EXEC_ENABLED and ctid.isdigit(),
            "why_not": None if EXEC_ENABLED and ctid.isdigit() else
            ("Active la section Commandes pour mettre à jour depuis l'app." if not EXEC_ENABLED else
             "Fais une dernière mise à jour depuis le Shell de Proxmox pour activer ce bouton.")}


def r_update(_):
    v = r_version({"check": 1})
    if not v["can_update"]:
        raise ApiError(409, v["why_not"])
    if not v["available"]:
        raise ApiError(409, v["error"] or "Déjà à jour")
    sha = _upd["data"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha or ""):
        raise ApiError(502, "Réponse GitHub inattendue")
    url = f"https://raw.githubusercontent.com/{UPDATE_REPO}/{sha}/pvehub-install.sh"
    cmd = f"bash <(curl -fsSL {url}) update {int(read_local('CTID'))}"
    # l'installeur redémarre l'app 3 s après avoir fini : la réponse a le temps de partir
    code, out = run_ssh(f"bash -c {shlex.quote(cmd)}", timeout=240)
    if code != 0:
        raise ApiError(502, "La mise à jour a échoué :\n" + out[-1500:])
    return {"ok": True, "version": v["remote"], "output": out[-1500:]}


# ---------------------------------------------------------------- Mes apps
# Ports qui ne sont jamais des interfaces web (SSH, DNS, bases de données, MQTT…)
NOT_WEB = {21, 22, 23, 25, 53, 110, 111, 123, 135, 137, 138, 139, 143, 389, 445, 465, 587, 631, 636, 993, 995,
           1883, 2049, 3306, 5353, 5432, 6379, 8883, 11211, 27017}
PORT_NAMES = {8123: "Home Assistant", 8096: "Jellyfin", 32400: "Plex", 9000: "Portainer", 9443: "Portainer",
              8642: "Hermes", 9091: "Transmission", 8989: "Sonarr", 7878: "Radarr", 9696: "Prowlarr",
              8384: "Syncthing", 5678: "n8n", 3001: "Uptime Kuma", 19999: "Netdata", 8000: "", 8080: ""}
HTTPS_PORTS = {443, 8443, 9443}
_scan = {"at": 0, "data": {}}
_apps_lock = threading.Lock()
NO_VERIFY = ssl.create_default_context()
NO_VERIFY.check_hostname = False
NO_VERIFY.verify_mode = ssl.CERT_NONE


def guest_ip(g):
    try:
        if g["type"] == "lxc":
            for i in pve("GET", f"/nodes/{g['node']}/lxc/{g['vmid']}/interfaces", timeout=5) or []:
                ip = (i.get("inet") or "").split("/")[0]
                if i.get("name") != "lo" and ip and not ip.startswith("127."):
                    return ip
        else:
            res = (pve("GET", f"/nodes/{g['node']}/qemu/{g['vmid']}/agent/network-get-interfaces", timeout=5) or {})
            for i in res.get("result", []):
                for a in i.get("ip-addresses", []):
                    ip = a.get("ip-address", "")
                    if a.get("ip-address-type") == "ipv4" and not ip.startswith("127.") and i.get("name") != "lo":
                        return ip
    except ApiError:
        pass  # VM sans agent QEMU, conteneur arrêté… : pas d'IP connue
    return None


def parse_ports(text):
    """Ports TCP en écoute hors localhost, depuis `ss -Htln` ou `netstat -tln` (4e colonne dans les deux)."""
    ports = set()
    for line in text.splitlines():
        cols = line.split()
        if len(cols) < 4 or (cols[0] == "tcp" and "LISTEN" not in line):
            continue
        host, _, port = cols[3].rpartition(":")
        if port.isdigit() and not re.match(r"^\[?(127\.|::1\]?$|localhost)", host):
            ports.add(int(port))
    return ports


def scan_ports(guests):
    """Une seule connexion SSH : ports en écoute de chaque machine allumée. {"lxc/101": {8123, ...}}"""
    if not EXEC_ENABLED or not guests:
        return {}
    probe = "ss -Htln 2>/dev/null || netstat -tln 2>/dev/null"
    script = "".join(
        f"echo @@{g['type']}/{g['vmid']}; " + (
            f"timeout 6 pct exec {g['vmid']} -- sh -c {shlex.quote(probe)} 2>/dev/null; " if g["type"] == "lxc" else
            f"timeout 9 qm guest exec {g['vmid']} --timeout 6 -- sh -c {shlex.quote(probe)} 2>/dev/null; ")
        for g in guests)
    _code, out = run_ssh(f"sh -c {shlex.quote(script)}", timeout=120)
    found, cur, buf = {}, None, []
    for line in out.splitlines() + ["@@end"]:
        if line.startswith("@@"):
            if cur:
                text = "\n".join(buf)
                try:  # qm guest exec renvoie du JSON
                    text = json.loads(text).get("out-data", "")
                except ValueError:
                    pass
                found[cur] = parse_ports(text)
            cur, buf = line[2:].strip(), []
        else:
            buf.append(line)
    return found


def load_apps_cfg():
    try:
        with open(APPS_FILE, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {}
    cfg.setdefault("over", {})
    cfg.setdefault("links", [])
    return cfg


def save_apps_cfg(cfg):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = APPS_FILE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=1)
        os.replace(tmp, APPS_FILE)
    except OSError as e:
        raise ApiError(500, f"Impossible d'enregistrer ({e.strerror}). Relance la mise à jour de PVE Hub.")


UP_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}),  # test direct, jamais via un proxy
                                         urllib.request.HTTPSHandler(context=NO_VERIFY))


def is_up(url):
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "PVEHub"})
    try:
        with UP_OPENER.open(req, timeout=3):
            return True
    except urllib.error.HTTPError:
        return True  # 401, 404… : le service répond
    except (urllib.error.URLError, OSError, ValueError):
        return False


def r_apps(q):
    guests = [g for g in pve("GET", "/cluster/resources", {"type": "vm"}) or []
              if g.get("status") == "running" and not g.get("template")]
    if q.get("rescan") or time.time() - _scan["at"] > 60:
        with ThreadPoolExecutor(8) as ex:
            ips = dict(zip((g["id"] for g in guests), ex.map(guest_ip, guests)))
        ports = scan_ports(guests)
        _scan.update(at=time.time(), data={"ips": ips, "ports": ports})
    ips, ports = _scan["data"].get("ips", {}), _scan["data"].get("ports", {})
    cfg = load_apps_cfg()
    apps = []
    for g in sorted(guests, key=lambda g: g["vmid"]):
        ip, web = ips.get(g["id"]), sorted(p for p in ports.get(g["id"], ()) if p not in NOT_WEB)
        if not ip or not web:
            continue
        for p in web:
            url = f"{'https' if p in HTTPS_PORTS else 'http'}://{ip}{'' if p in (80, 443) else f':{p}'}{'/web' if p == 32400 else ''}"
            label = PORT_NAMES.get(p, "")
            name = g.get("name") or str(g["vmid"])
            if len(web) > 1:
                name = f"{name} · {label or p}"
            apps.append({"id": f"{g['id']}:{p}", "name": name, "url": url, "guest": f"{g['type']}/{g['vmid']}"})
    for link in cfg["links"]:
        apps.append({**link, "custom": True})
    for a in apps:
        a.update({k: v for k, v in cfg["over"].get(a["id"], {}).items() if k in ("name", "url", "hidden")})
    visible = [a for a in apps if not a.get("hidden")]
    with ThreadPoolExecutor(16) as ex:
        for a, up in zip(visible, ex.map(lambda a: is_up(a["url"]), visible)):
            a["up"] = up
    return {"apps": apps, "scan": EXEC_ENABLED}


def clean_url(u):
    u = str(u or "").strip()
    if not re.match(r"^https?://[^\s/]+", u) or len(u) > 300:
        raise ApiError(400, "Adresse invalide (elle doit commencer par http:// ou https://)")
    return u


def r_apps_save(d):
    with _apps_lock:
        cfg = load_apps_cfg()
        aid = str(d.get("id", ""))[:80]
        name = str(d.get("name", "")).strip()[:60]
        if d.get("op") == "add":
            if not name:
                raise ApiError(400, "Donne un nom")
            cfg["links"].append({"id": "link:" + secrets.token_hex(4), "name": name, "url": clean_url(d.get("url"))})
        elif d.get("op") == "delete":
            cfg["links"] = [l for l in cfg["links"] if l["id"] != aid]
            cfg["over"].pop(aid, None)
        elif d.get("op") == "edit" and aid:
            over = cfg["over"].setdefault(aid, {})
            if "name" in d:
                over["name"] = name  # vide = revenir au nom détecté
            if "url" in d:
                over["url"] = clean_url(d["url"])
            if "hidden" in d:
                over["hidden"] = bool(d["hidden"])
            cfg["over"][aid] = {k: v for k, v in over.items() if v not in ("", None, False)}
        else:
            raise ApiError(400, "Demande invalide")
        save_apps_cfg(cfg)
    return {"ok": True}


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
    ("POST", "/api/chat/approval"): r_approval,
    ("POST", "/api/exec"): r_exec,
    ("GET", "/api/version"): r_version,
    ("POST", "/api/update"): r_update,
    ("GET", "/api/apps"): r_apps,
    ("POST", "/api/apps/save"): r_apps_save,
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
