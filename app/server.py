#!/usr/bin/env python3
"""PVE Hub — petite interface Proxmox + chat Hermes.

Aucune dépendance : uniquement la bibliothèque standard Python 3.9+.
Configuration via variables d'environnement ou fichier .env à côté du script.
"""
import base64
import hashlib
import hmac
import http.client
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


APP_FILE = os.path.join(DATA_DIR, "app.json")  # réglages de l'app communs à tous les appareils


def hermes_on():
    """Hermes configuré (HERMES_URL) et non désactivé dans Réglages."""
    return bool(HERMES_URL) and read_json(APP_FILE, {}).get("hermes", True)


def r_app_settings(d):
    with _apps_lock:
        st = read_json(APP_FILE, {})
        if "hermes" in d:
            st["hermes"] = bool(d["hermes"])
        write_json(APP_FILE, st)
    return {"ok": True, "hermes": hermes_on()}


def hermes(method, path, body=None, stream=False, timeout=30):
    if not hermes_on():
        raise ApiError(503, "Hermes est désactivé dans Réglages" if HERMES_URL else "Hermes n'est pas configuré (HERMES_URL)")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{HERMES_URL}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {HERMES_KEY}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if stream:
        req.add_header("Accept", "text/event-stream")
    try:
        r = urllib.request.urlopen(req, timeout=900 if stream else timeout)
    except urllib.error.HTTPError as e:
        raise ApiError(502, f"Hermes : {e.code} {e.read().decode(errors='replace')[:200]}")
    except (urllib.error.URLError, OSError) as e:
        raise ApiError(502, f"Hermes injoignable : {getattr(e, 'reason', e)}")
    if stream:
        return r
    with r:
        return json.loads(r.read() or b"{}")


def ssh_cmd(remote):
    host = urllib.parse.urlsplit(PVE_URL).hostname
    return ["ssh", "-i", SSH_KEY, "-o", f"UserKnownHostsFile={SSH_DIR}/known_hosts",
            "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "LogLevel=ERROR", f"root@{host}", remote]


def run_ssh_stream(remote, on_line, timeout=3600):
    """Comme run_ssh, mais chaque ligne de sortie est transmise dès qu'elle arrive (installations longues)."""
    p = subprocess.Popen(ssh_cmd(remote), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    killer = threading.Timer(timeout, p.kill)
    killer.start()
    try:
        for raw in p.stdout:
            on_line(raw.decode("utf-8", "replace"))
        return p.wait()
    finally:
        killer.cancel()


def run_ssh(remote, timeout=60):
    cmd = ssh_cmd(remote)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, f"(délai dépassé : {timeout} s)"
    except FileNotFoundError:
        return 127, "ssh introuvable dans le conteneur : apk add openssh-client-default (ou relance la mise à jour)"
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

# data/auth.json : {"pw": "pbkdf2$…" (remplace APP_PASSWORD une fois changé dans l'app),
#                    "sessions": {id: {t, seen, ip, who, ua}}, "log": [...], "warned": t}
AUTH_FILE = os.path.join(DATA_DIR, "auth.json")
_auth_lock = threading.Lock()


def auth_state():
    return read_json(AUTH_FILE, {})


def hash_pw(pw, salt=None, it=200_000):
    salt = salt or secrets.token_hex(16)
    return f"pbkdf2${it}${salt}${hashlib.pbkdf2_hmac('sha256', pw.encode(), salt.encode(), it).hex()}"


def check_password(pw):
    stored = auth_state().get("pw")
    if stored:
        _, it, salt, _h = stored.split("$")
        return hmac.compare_digest(hash_pw(pw, salt, int(it)), stored)
    return hmac.compare_digest(pw.encode(), APP_PASSWORD.encode())


def auth_enabled():
    return bool(APP_PASSWORD or auth_state().get("pw"))


def _sign(exp, sid):
    return hmac.new(APP_SECRET, f"{exp}.{sid}".encode(), hashlib.sha256).hexdigest()


def make_session(ip="", who="", ua=""):
    """Chaque connexion a son identifiant, gardé côté serveur : on peut la couper seule depuis Réglages → Sécurité."""
    now = int(time.time())
    sid, exp = secrets.token_hex(8), now + SESSION_DAYS * 86400
    with _auth_lock:
        st = auth_state()
        ses = {k: v for k, v in st.get("sessions", {}).items() if v["t"] + SESSION_DAYS * 86400 > now}  # expirées
        ses[sid] = {"t": now, "seen": now, "ip": ip[:64], "who": who[:80], "ua": ua[:120]}
        st["sessions"] = dict(sorted(ses.items(), key=lambda kv: kv[1]["seen"])[-20:])  # 20 appareils au plus
        write_json(AUTH_FILE, st)
    return f"{exp}.{sid}.{_sign(exp, sid)}"


_seen = {}


def session_id(value):
    """Identifiant de la session si le cookie est valide et la session toujours ouverte, sinon None."""
    try:
        exp, sid, sig = value.split(".")
        if not hmac.compare_digest(sig, _sign(exp, sid)) or int(exp) < time.time():
            return None
    except (ValueError, AttributeError):
        return None
    if sid not in auth_state().get("sessions", {}):
        return None
    now = int(time.time())
    if now - _seen.get(sid, 0) > 300:  # « dernière activité » à 5 min près : pas d'écriture à chaque requête
        _seen[sid] = now
        with _auth_lock:
            st = auth_state()
            if sid in st.get("sessions", {}):
                st["sessions"][sid]["seen"] = now
                write_json(AUTH_FILE, st)
    return sid


def end_sessions(keep=None, only=None, **changes):
    """only : ferme cette session ; sinon ferme toutes les sessions sauf keep. changes : ex. nouveau mot de passe."""
    with _auth_lock:
        st = auth_state()
        ses = st.get("sessions", {})
        st["sessions"] = {k: v for k, v in ses.items() if (k != only if only else k == keep)}
        st.update(changes)
        write_json(AUTH_FILE, st)


def log_login(ok, ip, who, ua):
    """Garde les 30 dernières tentatives ; prévient par notification en cas d'échec (au plus une fois par 10 min)."""
    now = int(time.time())
    with _auth_lock:
        st = auth_state()
        warn = not ok and now - st.get("warned", 0) > 600
        if warn:
            st["warned"] = now
        write_json(AUTH_FILE, st)
    log_event("login", "Connexion" if ok else "Mot de passe incorrect", who or ip, ok=ok, ua=ua[:120])
    if warn:
        threading.Thread(target=send_push, args=("🔐 Mot de passe incorrect",
                         f"Tentative de connexion refusée depuis {who or ip}.", "/#journal=login", "login"), daemon=True).start()


# ---------------------------------------------------------------- HTTP

MIME = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css",
        ".svg": "image/svg+xml", ".webmanifest": "application/manifest+json", ".png": "image/png"}


class Handler(BaseHTTPRequestHandler):
    server_version = "PVEHub/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("DEBUG"):
            super().log_message(fmt, *args)

    def end_headers(self):
        # interdit d'afficher l'app dans un cadre d'un autre site (clics piégés)
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "same-origin")
        super().end_headers()

    def client(self):
        # X-Forwarded-For / Tailscale-User-Login viennent de « tailscale serve » ; falsifiables en accès direct, juste pour le journal
        ip = (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()
        return ip, self.headers.get("Tailscale-User-Login", ""), self.headers.get("User-Agent", "")

    def cookie(self, value, max_age):
        https = self.headers.get("X-Forwarded-Proto") == "https" or (self.headers.get("Origin") or "").startswith("https://")
        # Secure seulement en HTTPS, sinon le navigateur refuserait le cookie en http://IP locale
        return {"Set-Cookie": f"pvehub={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Strict{'; Secure' if https else ''}"}

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
        # pas de SimpleCookie : un cookie mal formé posé par une autre app du même hôte lui fait ignorer la suite
        jar = dict(p.strip().split("=", 1) for p in self.headers.get("Cookie", "").split(";") if "=" in p)
        self.sid = session_id(jar["pvehub"]) if "pvehub" in jar else None
        return bool(self.sid) or not auth_enabled()

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
            # un formulaire d'un autre site ne peut pas envoyer du JSON sans autorisation du navigateur (CSRF)
            if method == "POST" and not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise ApiError(415, "Requête JSON attendue")
            if path == "/api/login" and method == "POST":
                return self.login()
            if path == "/api/logout" and method == "POST":
                if self.authed() and self.sid:
                    end_sessions(only=self.sid)
                return self.send_json({"ok": True}, extra=self.cookie("", 0))
            if not self.authed():
                raise ApiError(401, "Non connecté")
            if path == "/api/auth" and method == "GET":
                return self.send_json(self.auth_info())
            if path == "/api/auth/revoke" and method == "POST":
                sid = str(self.body().get("id") or "")
                gone = auth_state().get("sessions", {}).get(sid, {})
                end_sessions(only=sid) if sid else end_sessions(keep=self.sid)  # une session, ou toutes sauf celle-ci
                if sid != self.sid:
                    log_event("security", "Appareil déconnecté" if sid else "Autres appareils déconnectés",
                              gone.get("who") or gone.get("ip", ""), ua=gone.get("ua", ""))
                return self.send_json({"ok": True, "self": sid == self.sid})
            if path == "/api/auth/password" and method == "POST":
                return self.change_password()
            route = ROUTES.get((method, path))
            if not route:
                raise ApiError(404, "Route inconnue")
            if path in ("/api/chat", "/api/chat/stream"):
                return route(self)
            data = self.qs() if method == "GET" else self.body()
            self.send_json(route(data))
        except ApiError as e:
            self.send_json({"error": e.msg}, e.status)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # noqa: BLE001
            print("Erreur :", repr(e), file=sys.stderr)
            try:  # le type d'erreur aide à diagnostiquer sans aller lire le journal
                self.send_json({"error": f"Erreur interne ({type(e).__name__} : {str(e)[:150]})"}, 500)
            except OSError:
                pass

    def login(self):
        d = self.body()
        if not auth_enabled():
            return self.send_json({"ok": True})
        ok = check_password(str(d.get("password", "")))
        log_login(ok, *self.client())
        if ok:
            return self.send_json({"ok": True}, extra=self.cookie(make_session(*self.client()), SESSION_DAYS * 86400))
        time.sleep(1.5)
        raise ApiError(403, "Mot de passe incorrect")

    def change_password(self):
        d = self.body()
        new = str(d.get("new", ""))
        if auth_enabled() and not check_password(str(d.get("current", ""))):
            time.sleep(1.5)
            raise ApiError(403, "Mot de passe actuel incorrect")
        if len(new) < 10 or len(new) > 200:
            raise ApiError(400, "Le nouveau mot de passe doit faire au moins 10 caractères")
        end_sessions(keep=self.sid, pw=hash_pw(new))  # les autres appareils devront se reconnecter
        log_event("security", "Mot de passe changé", "Les autres appareils ont été déconnectés")
        if self.sid:
            return self.send_json({"ok": True})
        # pas encore de mot de passe jusque-là : cet appareil reçoit sa première session
        return self.send_json({"ok": True}, extra=self.cookie(make_session(*self.client()), SESSION_DAYS * 86400))

    def auth_info(self):
        st = auth_state()
        ses = [{"id": k, **v, "current": k == self.sid} for k, v in st.get("sessions", {}).items()]
        return {"enabled": auth_enabled(), "custom": bool(st.get("pw")),
                "sessions": sorted(ses, key=lambda x: (not x["current"], -x["seen"]))}

    # -- chat : la réponse est suivie par le serveur (l'app peut se fermer), l'app s'y abonne et peut s'y raccrocher
    def chat(self):
        if not hermes_on():
            raise ApiError(503, "Hermes est désactivé dans Réglages" if HERMES_URL else "Hermes n'est pas configuré (HERMES_URL)")
        d = self.body()
        msgs = []
        for m in (d.get("messages") or [])[-40:]:
            if m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str):
                msgs.append({"role": m["role"], "content": m["content"][:20000]})
        if not msgs:
            raise ApiError(400, "Message vide")
        if msgs[-1]["role"] != "user":
            raise ApiError(400, "Le dernier message doit venir de toi")
        conv = str(d.get("conv") or "")
        conv = conv if RE_CHAT.match(conv) else None
        try:
            summary = cluster_summary()
        except ApiError as e:
            summary = f"(état indisponible : {e.msg})"
        system = SYSTEM_PROMPT.format(now=local_now().strftime("%d/%m/%Y %H:%M"), summary=summary)
        # API « runs » : seule à exposer les demandes d'autorisation de Hermes (approval.request)
        run = hermes("POST", "/v1/runs", {"input": msgs[-1]["content"], "instructions": system,
                                           "conversation_history": msgs[:-1]})
        run_id = str(run.get("run_id", ""))
        if not RE_RUN.match(run_id):
            raise ApiError(502, "Hermes : réponse inattendue")
        upstream = hermes("GET", f"/v1/runs/{run_id}/events", stream=True)
        now = time.time()
        for k in [k for k, r in list(_runs.items()) if r["done"] and now - r["at"] > 3600]:
            del _runs[k]
        _runs[run_id] = {"events": [], "done": False, "conv": conv, "listeners": 0, "at": now, "cond": threading.Condition()}
        threading.Thread(target=pump_run, args=(run_id, upstream), daemon=True).start()
        return self.send_json({"run_id": run_id})

    def chat_stream(self):
        """Événements d'une réponse en cours ou terminée, depuis le début ; « : ping » toutes les 3 s (détecte l'app fermée)."""
        run = _runs.get(self.qs().get("run", ""))
        if not run:
            raise ApiError(404, "Réponse introuvable (PVE Hub a peut-être redémarré)")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        idx, cond = 0, run["cond"]
        with cond:
            run["listeners"] += 1
        try:
            while True:
                with cond:
                    if idx >= len(run["events"]) and not run["done"]:
                        cond.wait(3)
                    evs, done = run["events"][idx:], run["done"]
                for e in evs:
                    self.wfile.write(f"data: {json.dumps(e)}\n\n".encode())
                idx += len(evs)
                if not evs:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
                if done and idx >= len(run["events"]):
                    self.wfile.write(b'data: {"event": "pvehub.end"}\n\n')
                    self.wfile.flush()
                    break
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with cond:
                run["listeners"] -= 1


_runs = {}  # run_id -> {events, done, conv, listeners, at, cond} : réponses de Hermes suivies par le serveur


def apply_event(reply, ev):
    """Même logique que l'app : construit la réponse à partir des événements de Hermes. Retourne True à la fin."""
    e = ev.get("event")
    if e == "message.delta":
        reply["content"] += ev.get("delta") or ""
    elif e == "tool.started" and ev.get("tool") and ev["tool"] not in reply["tools"]:
        reply["tools"].append(ev["tool"])
    elif e == "approval.request":
        reply["approvals"].append({k: ev.get(k) for k in ("command", "description", "choices", "request_id")})
    elif e == "approval.responded":
        p = next((a for a in reply["approvals"] if not a.get("answer")), None)
        if p:
            p["answer"] = ev.get("choice")
    elif e == "run.completed":
        if ev.get("output"):
            reply["content"] = ev["output"]
        return True
    elif e in ("run.failed", "run.interrupted"):
        reply["content"] += ("\n\n" if reply["content"] else "") + "⚠️ " + str(ev.get("error") or "Hermes a échoué")
        return True
    elif e == "run.cancelled":
        reply["content"] += ("\n\n" if reply["content"] else "") + "_(annulé)_"
        return True
    return False


def pump_run(run_id, upstream):
    """Lit la réponse de Hermes jusqu'au bout, même si plus personne n'écoute ; à la fin, l'enregistre et notifie."""
    run, reply = _runs[run_id], {"role": "assistant", "content": "", "tools": [], "approvals": [], "runId": run_id}
    url = f"/#chat={run['conv']}" if run["conv"] else "/"

    def add(ev):
        with run["cond"]:
            run["events"].append(ev)
            run["cond"].notify_all()
            alone = run["listeners"] == 0
        end = apply_event(reply, ev)
        if ev.get("event") == "approval.request" and alone:
            send_push("🛡️ Hermes attend ton autorisation", str(ev.get("command") or ev.get("description") or "")[:140], url, f"chat-{run_id}")
        return end
    try:
        with upstream:
            data = []
            for raw in upstream:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("data:"):
                    data.append(line[5:].lstrip())
                elif not line and data:
                    try:
                        ev = json.loads("\n".join(data))
                    except ValueError:
                        ev = None
                    data = []
                    if isinstance(ev, dict) and add(ev):
                        break
            else:
                if not any(e.get("event", "").startswith("run.") for e in run["events"]):
                    add({"event": "run.interrupted", "error": "Hermes a coupé la connexion"})
    except Exception as e:  # noqa: BLE001 — réseau coupé, Hermes redémarré… : la réponse est close proprement
        add({"event": "run.interrupted", "error": f"Connexion à Hermes perdue ({type(e).__name__})"})
    finally:
        with run["cond"]:
            run["done"], run["at"] = True, time.time()
            run["cond"].notify_all()
            alone = run["listeners"] == 0
        if run["conv"]:
            store_reply(run["conv"], reply)
        if alone:
            first = re.sub(r"[*_#`>]|```pvehub[\s\S]*?```", "", reply["content"]).strip().split("\n")[0][:140]
            send_push("💬 Hermes a répondu", first or "Réponse prête", url, f"chat-{run_id}")


def store_reply(conv, reply):
    """Enregistre la réponse dans la conversation (à la place du message « en cours » de l'app, sinon à la fin)."""
    with _chats_lock:
        chats = read_json(CHATS_FILE, {})
        c = chats.get(conv)
        if not c:
            return
        i = next((i for i, m in enumerate(c["messages"]) if m.get("runId") == reply["runId"]), None)
        if i is None:
            c["messages"].append(reply)
        else:
            c["messages"][i] = {**c["messages"][i], **reply, "typing": False}
        c["updated"] = int(time.time())
        write_json(CHATS_FILE, chats)


# ---------------------------------------------------------------- routes

def r_overview(_):
    nodes = pve("GET", "/nodes") or []
    guests = pve("GET", "/cluster/resources", {"type": "vm"}) or []
    storage = pve("GET", "/cluster/resources", {"type": "storage"}) or []
    return {"nodes": nodes, "guests": guests, "storage": storage, "hermes": hermes_on(), "hermes_configured": bool(HERMES_URL),
            "exec": EXEC_ENABLED}


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


# ---------------------------------------------------------------- maintenance : sauvegardes
def job_covers(job, vmid):
    """Une sauvegarde planifiée inclut-elle cette machine ?"""
    # shortcut: les jobs par pool sont ignorés ; ajouter /pools si quelqu'un les utilise
    if str(job.get("enabled", 1)) == "0":
        return False
    ids = lambda k: {int(x) for x in re.findall(r"\d+", str(job.get(k) or ""))}
    if str(job.get("all", 0)) == "1":
        return vmid not in ids("exclude")
    return vmid in ids("vmid")


def r_maint_backups(_):
    nodes = [n["node"] for n in pve("GET", "/nodes") or [] if n.get("status") == "online"]
    guests = [g for g in pve("GET", "/cluster/resources", {"type": "vm"}) or [] if not g.get("template")]
    try:
        jobs = pve("GET", "/cluster/backup") or []
    except ApiError:
        jobs = []
    last, failed = {}, []
    for node in nodes:
        for st in backup_storages(node):
            try:
                items = pve("GET", f"/nodes/{node}/storage/{st}/content", {"content": "backup"}) or []
            except ApiError:
                continue
            for it in items:
                v, cur = it.get("vmid"), last.get(it.get("vmid"))
                if v is not None and (not cur or it.get("ctime", 0) > cur["ctime"]):
                    last[v] = {"ctime": it.get("ctime", 0), "size": it.get("size", 0), "storage": st}
        try:
            for t in pve("GET", f"/nodes/{node}/tasks", {"typefilter": "vzdump", "limit": 30}) or []:
                if t.get("endtime") and t.get("status") not in (None, "OK") and time.time() - t["starttime"] < 7 * 86400:
                    failed.append({"starttime": t["starttime"], "status": t["status"], "vmid": t.get("id") or None})
        except ApiError:
            pass
    rows = []
    for g in sorted(guests, key=lambda g: g["vmid"]):
        b = last.get(g["vmid"])
        rows.append({"id": g["id"], "vmid": g["vmid"], "name": g.get("name", ""), "type": g["type"], "node": g["node"],
                     "last": b, "planned": any(job_covers(j, g["vmid"]) for j in jobs)})
    return {"guests": rows, "failed": failed[:5],
            "jobs": [{"schedule": j.get("schedule") or j.get("starttime"), "enabled": str(j.get("enabled", 1)) != "0",
                      "all": str(j.get("all", 0)) == "1", "vmid": j.get("vmid"), "storage": j.get("storage"),
                      "comment": j.get("comment")} for j in jobs]}


# ---------------------------------------------------------------- maintenance : mises à jour des conteneurs
# Liste des paquets à mettre à jour dans chaque conteneur (index rafraîchi avant), en parallèle sur l'hôte
UPD_PROBE = ("if command -v apk >/dev/null; then apk update -q >/dev/null 2>&1; echo pm=apk; apk list -u 2>/dev/null | cut -d' ' -f1; "
             "elif command -v apt-get >/dev/null; then apt-get update -qq >/dev/null 2>&1; echo pm=apt; "
             "apt list --upgradable 2>/dev/null | grep -v '^Listing' | cut -d/ -f1; else echo pm=none; fi")
_updates = {"at": 0, "running": False, "cts": {}, "error": None}
_jobs = {}  # mises à jour en cours : id -> {status, output, vmid}
_maint_lock = threading.Lock()


def guest_exec(g, script, timeout):
    """Commande shell qui lance un script dans un conteneur (pct exec) ou une VM (agent QEMU)."""
    if g["type"] == "lxc":
        return f"timeout {timeout} pct exec {g['vmid']} -- sh -c {shlex.quote(script)}"
    return f"timeout {timeout + 20} qm guest exec {g['vmid']} --timeout {timeout} -- sh -c {shlex.quote(script)}"


def qm_output(text):
    """Sortie de « qm guest exec » (JSON) → (code, texte) ; un texte qui n'est pas du JSON est rendu tel quel."""
    try:
        j = json.loads(text)
        if not j.get("exited"):  # délai atteint : qm ne renvoie que le pid, la commande tourne encore dans la VM
            return 124, "La commande tourne toujours dans la VM (délai dépassé)"
        return j.get("exitcode", 0), (j.get("out-data", "") + j.get("err-data", ""))
    except (ValueError, AttributeError):
        return None, text


def parse_updates(out):
    """Sortie du balayage : sections « @@id » puis « pm=… » et un paquet par ligne (JSON pour une VM)."""
    raw, cur = {}, None
    for line in out.splitlines():
        if line.startswith("@@") and (line[2:].isdigit() or line[2:] == "host"):
            cur = int(line[2:]) if line[2:].isdigit() else "host"
            raw[cur] = []
        elif cur is not None:
            raw[cur].append(line)
    found = {}
    for k, lines in raw.items():
        text = "\n".join(lines)
        if text.lstrip().startswith("{"):
            text = qm_output(text)[1]
        pm = next((l[3:] for l in text.splitlines() if l.startswith("pm=")), None)
        found[k] = {"pm": pm, "packages": [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("pm=")]}
    return found


def scan_updates():
    try:
        # conteneurs et VM allumés ; une VM sans agent QEMU (ou sous Windows) ressort sans gestionnaire de paquets
        cts = [g for g in pve("GET", "/cluster/resources", {"type": "vm"}) or []
               if g.get("status") == "running" and not g.get("template")]
        script = (f"d=$(mktemp -d); (sh -c {shlex.quote(UPD_PROBE)} > $d/host 2>/dev/null) & " + "".join(
            f"({guest_exec(g, UPD_PROBE, 180)} > $d/{g['vmid']} 2>/dev/null) & " for g in cts)
            + "wait; for f in $d/*; do [ -f \"$f\" ] && echo \"@@${f##*/}\" && cat \"$f\"; done; rm -rf $d")
        found = {}
        if EXEC_ENABLED:
            code, out = run_ssh(f"sh -c {shlex.quote(script)}", timeout=260)
            found = parse_updates(out)
        info = {g["vmid"]: g for g in cts}
        _updates["host"] = found.pop("host", None)
        _updates.update(cts={v: {**d, "name": info[v].get("name", ""), "type": info[v]["type"]} for v, d in found.items() if v in info},
                        error=None)
    except Exception as e:  # noqa: BLE001 — tâche de fond : l'erreur est montrée dans l'écran
        _updates["error"] = str(e)[:200]
    finally:
        _updates.update(at=time.time(), running=False)


def r_maint_updates(q):
    if not EXEC_ENABLED:
        raise ApiError(403, "Active la section Commandes pour voir les mises à jour des conteneurs")
    with _maint_lock:
        if not _updates["running"] and (q.get("refresh") or time.time() - _updates["at"] > 6 * 3600):
            _updates["running"] = True
            threading.Thread(target=scan_updates, daemon=True).start()
    return {"scanning": _updates["running"], "checked_at": int(_updates["at"]) or None, "error": _updates["error"],
            "host": _updates.get("host"), "cts": [{"vmid": v, **d} for v, d in sorted(_updates["cts"].items())],
            "jobs": {k: {kk: vv for kk, vv in j.items() if kk != "output"} for k, j in list(_jobs.items())}}


def run_upgrade(job_id, node, typ, vmid, snapshot):
    job = _jobs[job_id]
    try:
        if snapshot:
            job["status"] = "snapshot"
            name = "avant-maj-" + local_now().strftime("%Y%m%d-%H%M")
            upid = pve("POST", f"/nodes/{node}/{typ}/{vmid}/snapshot", {"snapname": name, "description": "Avant mise à jour (PVE Hub)"})
            for _ in range(120):  # attend la fin du snapshot (2 min max)
                st = pve("GET", f"/nodes/{node}/tasks/{urllib.parse.quote(upid, safe='')}/status") or {}
                if st.get("status") == "stopped":
                    if st.get("exitstatus") != "OK":
                        raise ApiError(502, f"Snapshot impossible : {st.get('exitstatus')}")
                    break
                time.sleep(1)
            job["snapshot"] = name
        job["status"] = "upgrade"
        pm = _updates["cts"].get(vmid, {}).get("pm")
        cmd = ("apk upgrade -q --no-cache" if pm == "apk" else
               "export DEBIAN_FRONTEND=noninteractive; apt-get -y -q -o Dpkg::Options::=--force-confdef "
               "-o Dpkg::Options::=--force-confold dist-upgrade && apt-get -y -q autoremove")
        code, out = run_ssh(guest_exec({"type": typ, "vmid": vmid}, cmd, 1500), timeout=1560)
        if typ == "qemu":
            c, out = qm_output(out)
            code = code if c is None else c
        job["output"] = out[-4000:]
        if code != 0:
            raise ApiError(502, f"La mise à jour a échoué (code {code})")
        job["status"] = "done"
        _updates["cts"].get(vmid, {})["packages"] = []
    except ApiError as e:
        job.update(status="error", error=e.msg)
    except Exception as e:  # noqa: BLE001
        job.update(status="error", error=str(e)[:200])
    name = _updates["cts"].get(vmid, {}).get("name") or f"{'VM' if typ == 'qemu' else 'Conteneur'} {vmid}"
    log_event("update", f"{name} mis à jour" if job["status"] == "done" else f"{name} : mise à jour en échec",
              job.get("error") or (f"Snapshot {job['snapshot']}" if job.get("snapshot") else ""), f"/#g={typ}/{vmid}")


def r_maint_upgrade(d):
    if not EXEC_ENABLED:
        raise ApiError(403, "Active la section Commandes")
    node, typ, vmid = guest_args({**d, "type": d.get("type") or "lxc"})
    with _maint_lock:
        if any(j["vmid"] == vmid and j["status"] in ("snapshot", "upgrade") for j in _jobs.values()):
            raise ApiError(409, "Mise à jour déjà en cours sur cette machine")
        for k in [k for k, j in _jobs.items() if time.time() - j["at"] > 86400]:
            del _jobs[k]  # on oublie les mises à jour terminées depuis plus d'un jour
        job_id = secrets.token_hex(6)
        _jobs[job_id] = {"vmid": vmid, "status": "start", "at": int(time.time())}
    threading.Thread(target=run_upgrade, args=(job_id, node, typ, vmid, bool(d.get("snapshot", True))), daemon=True).start()
    return {"job": job_id}


def r_maint_job(q):
    j = _jobs.get(str(q.get("id", "")))
    if not j:
        raise ApiError(404, "Tâche inconnue")
    return j


# ---------------------------------------------------------------- tâches planifiées (crontab de root)
# Un champ : *, nombres ou noms (jan, mon…), combinés par , - / — « m » ou « dow » ne passent pas
_TOK = r"(?:\*|\d+|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|sun|mon|tue|wed|thu|fri|sat)"
CRON_FIELD = rf"{_TOK}(?:[-/,]{_TOK})*"
_SPECIAL = r"@(?:reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)"
RE_CRON_JOB = re.compile(rf"^\s*({_SPECIAL}|(?:{CRON_FIELD}\s+){{4}}{CRON_FIELD})\s+(\S.*)$", re.I)
RE_CRON_SCHED = re.compile(rf"^({_SPECIAL}|(?:{CRON_FIELD} ){{4}}{CRON_FIELD})$", re.I)
CRON_READ = "command -v crontab >/dev/null || { echo @@nocron; exit 0; }; crontab -l 2>/dev/null; true"


def cron_target(d):
    """Enveloppe un script sh pour l'hôte ou un conteneur."""
    if d.get("type") in (None, "", "host"):
        return lambda script: f"sh -c {shlex.quote(script)}"
    _node, typ, vmid = guest_args(d)
    if typ != "lxc":
        raise ApiError(400, "Les tâches planifiées se gèrent sur l'hôte ou dans un conteneur")
    return lambda script: f"pct exec {vmid} -- sh -c {shlex.quote(script)}"


def parse_cron(text):
    """Une entrée par ligne ; les tâches désactivées sont des lignes de tâche commentées par « # »."""
    entries = []
    for i, line in enumerate(text.split("\n")):
        body, enabled = line, True
        if line.lstrip().startswith("#"):
            body, enabled = line.lstrip()[1:].lstrip(), False
        m = RE_CRON_JOB.match(body)
        if m:
            sched = re.sub(r"\s+", " ", m.group(1))
            entries.append({"i": i, "job": True, "enabled": enabled, "sched": sched, "cmd": m.group(2).rstrip()})
        else:
            entries.append({"i": i, "job": False, "raw": line})
    return entries


def cron_hash(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def read_cron(wrap):
    if not EXEC_ENABLED:
        raise ApiError(403, "Active la section Commandes pour gérer les tâches planifiées")
    code, out = run_ssh(wrap(CRON_READ), timeout=20)
    if code not in (0,) and "@@nocron" not in out:
        raise ApiError(502, out.strip()[-300:] or "Lecture impossible")
    if "@@nocron" in out:
        return None
    return out.rstrip("\n")


def r_cron(q):
    text = read_cron(cron_target(q))
    if text is None:
        return {"available": False}
    return {"available": True, "hash": cron_hash(text),
            "entries": [e for e in parse_cron(text) if e["job"]]}


def r_cron_save(d):
    wrap = cron_target(d)
    text = read_cron(wrap)
    if text is None:
        raise ApiError(409, "cron n'est pas installé sur cette machine")
    if d.get("hash") != cron_hash(text):
        raise ApiError(409, "La crontab a changé entre-temps : recharge la liste")
    lines = text.split("\n") if text else []
    op = d.get("op")
    if op in ("add", "edit"):
        sched = re.sub(r"\s+", " ", str(d.get("sched", "")).strip())
        cmd = str(d.get("cmd", "")).strip()
        if not RE_CRON_SCHED.match(sched):
            raise ApiError(400, "Planification invalide (5 champs, ex. « 0 3 * * * », ou @daily, @reboot…)")
        if not cmd or len(cmd) > 1000 or "\n" in cmd or "\r" in cmd:
            raise ApiError(400, "Commande vide, trop longue ou sur plusieurs lignes")
        new = f"{sched} {cmd}"
    i = d.get("i")
    if op != "add":
        if not isinstance(i, int) or not 0 <= i < len(lines) or not parse_cron(lines[i])[0]["job"]:
            raise ApiError(400, "Tâche introuvable")
    if op == "add":
        lines.append(new)
    elif op == "edit":
        lines[i] = new if parse_cron(lines[i])[0]["enabled"] else "#" + new
    elif op == "toggle":
        e = parse_cron(lines[i])[0]
        lines[i] = ("#" if e["enabled"] else "") + f"{e['sched']} {e['cmd']}"
    elif op == "delete":
        del lines[i]
    else:
        raise ApiError(400, "Demande invalide")
    payload = base64.b64encode(("\n".join(lines) + "\n").encode()).decode()
    code, out = run_ssh(wrap(f"echo {payload} | base64 -d | crontab -"), timeout=20)
    if code != 0:
        raise ApiError(502, "Écriture refusée : " + out.strip()[-300:])
    return r_cron(d)


# ---------------------------------------------------------------- notifications (Web Push : RFC 8291 + VAPID RFC 8292)
PUSH_FILE = os.path.join(DATA_DIR, "push.json")        # abonnements des appareils
VAPID_FILE = os.path.join(DATA_DIR, "vapid.pem")       # clé privée du serveur, créée au premier usage
ALERTS_FILE = os.path.join(DATA_DIR, "alerts.json")    # réglages des alertes + petit état persistant
_push_lock = threading.Lock()
try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    PUSH_OK = True
except ImportError:  # paquet py3-cryptography absent : notifications indisponibles, le reste marche
    PUSH_OK = False


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = f"{path}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


# Journal : alertes, connexions, actions (Store, mises à jour, sécurité) — les 300 derniers événements
EVENTS_FILE = os.path.join(DATA_DIR, "events.json")
EVENT_KINDS = {"alert", "login", "security", "store", "update", "report"}
_events_lock = threading.Lock()


def log_event(kind, title, body="", url=None, **extra):
    try:
        with _events_lock:
            ev = read_json(EVENTS_FILE, [])
            ev.append({"ts": int(time.time()), "kind": kind, "title": title[:120], "body": str(body)[:300], "url": url, **extra})
            write_json(EVENTS_FILE, ev[-300:])
    except OSError as e:  # le journal ne doit jamais bloquer l'action qu'il raconte
        print("Journal :", repr(e), file=sys.stderr)


# Conversations Hermes : sur le serveur, donc les mêmes sur tous les appareils
CHATS_FILE = os.path.join(DATA_DIR, "chats.json")
RE_CHAT = re.compile(r"^[a-f0-9]{8,32}$")
_chats_lock = threading.Lock()


def r_chats(_):
    chats = read_json(CHATS_FILE, {})
    return {"chats": sorted(({"id": c["id"], "title": c["title"], "updated": c["updated"], "count": len(c["messages"]),
                              "report": c.get("report")} for c in chats.values()), key=lambda c: -c["updated"])}


def r_chat_get(q):
    c = read_json(CHATS_FILE, {}).get(str(q.get("id", "")))
    if not c:
        raise ApiError(404, "Conversation introuvable")
    return c


def r_chat_save(d):
    cid, msgs = str(d.get("id", "")), d.get("messages")
    if not RE_CHAT.match(cid) or not isinstance(msgs, list):
        raise ApiError(400, "Conversation invalide")
    msgs = [m for m in msgs if isinstance(m, dict) and m.get("role") in ("user", "assistant", "note")][-150:]
    title = re.sub(r"\s+", " ", str(d.get("title") or "")).strip()[:80]
    with _chats_lock:
        chats = read_json(CHATS_FILE, {})
        old = chats.get(cid, {})
        # une réponse terminée par le serveur ne redevient jamais « en cours » à cause d'un appareil en retard
        done = {m["runId"]: m for m in old.get("messages", []) if m.get("runId") and not m.get("typing")}
        msgs = [done.get(m.get("runId"), m) if m.get("typing") else m for m in msgs]
        chats[cid] = {"id": cid, "title": title or old.get("title") or "Conversation", "created": old.get("created", int(time.time())),
                      "updated": int(time.time()), "report": d.get("report") or old.get("report"), "messages": msgs}
        # 100 conversations au plus : les plus anciennes partent
        write_json(CHATS_FILE, dict(sorted(chats.items(), key=lambda kv: kv[1]["updated"])[-100:]))
    return {"ok": True}


def r_chat_delete(d):
    with _chats_lock:
        chats = read_json(CHATS_FILE, {})
        chats.pop(str(d.get("id", "")), None)
        write_json(CHATS_FILE, chats)
    return {"ok": True}


def r_events(q):
    ev = read_json(EVENTS_FILE, [])
    kind = q.get("kind")
    return {"events": [e for e in reversed(ev) if not kind or e["kind"] == kind]}


def raw_pub(key):
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def vapid_key():
    with _push_lock:
        try:
            with open(VAPID_FILE, "rb") as f:
                return serialization.load_pem_private_key(f.read(), None)
        except OSError:
            key = ec.generate_private_key(ec.SECP256R1())
            os.makedirs(DATA_DIR, exist_ok=True)
            with open(VAPID_FILE, "wb") as f:
                os.chmod(VAPID_FILE, 0o600)
                f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
            return key


def vapid_header(endpoint, key):
    aud = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(endpoint))
    claims = {"aud": aud, "exp": int(time.time()) + 3000, "sub": f"https://github.com/{UPDATE_REPO}"}
    signing_input = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}).encode()) + "." + b64u(json.dumps(claims).encode())
    r, s = decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    jwt = signing_input + "." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    return f"vapid t={jwt}, k={b64u(raw_pub(key))}"


def hkdf(salt, ikm, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


def encrypt_push(payload, p256dh, auth, salt=None, eph=None):
    """Chiffrement aes128gcm d'un message pour un abonnement (RFC 8291). salt/eph : fixés seulement pour les tests."""
    ua_pub = unb64u(p256dh)
    eph = eph or ec.generate_private_key(ec.SECP256R1())
    as_pub = raw_pub(eph)
    secret = eph.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_pub))
    ikm = hkdf(unb64u(auth), secret, b"WebPush: info\x00" + ua_pub + as_pub, 32)
    salt = salt or secrets.token_bytes(16)
    cek = hkdf(salt, ikm, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = hkdf(salt, ikm, b"Content-Encoding: nonce\x00", 12)
    body = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)
    return salt + (4096).to_bytes(4, "big") + bytes([len(as_pub)]) + as_pub + body


def send_push(title, body, url="/", tag=None):
    """Envoie à tous les appareils abonnés. Retourne le nombre d'envois réussis ; retire les abonnements expirés."""
    if not PUSH_OK:
        return 0
    key, ok, gone = vapid_key(), 0, []
    payload = json.dumps({"title": title, "body": body, "url": url, "tag": tag}).encode()
    for sub in read_json(PUSH_FILE, []):
        try:
            req = urllib.request.Request(sub["endpoint"], method="POST",
                                         data=encrypt_push(payload, sub["keys"]["p256dh"], sub["keys"]["auth"]))
            for k, v in {"Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "TTL": "86400",
                         "Urgency": "high", "Authorization": vapid_header(sub["endpoint"], key)}.items():
                req.add_header(k, v)
            urllib.request.urlopen(req, timeout=15).close()
            ok += 1
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                gone.append(sub["endpoint"])  # appareil désabonné ou app supprimée
            print("Notification refusée :", e.code, e.read()[:200], file=sys.stderr)
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            print("Notification non envoyée :", repr(e), file=sys.stderr)
    if gone:
        with _push_lock:
            write_json(PUSH_FILE, [s for s in read_json(PUSH_FILE, []) if s["endpoint"] not in gone])
    return ok


ALERT_DEFAULTS = {"stopped": True, "disk": True, "disk_threshold": 90, "backup": True, "updates": True, "apps": True, "smart": True,
                  "report": False, "report_time": "08:00", "tz": os.environ.get("TZ") or "UTC"}
REPORTS_FILE = os.path.join(DATA_DIR, "reports.json")  # derniers rapports du matin


def local_time(ts=None, s=None):
    """Date locale de l'utilisateur (fuseau envoyé par son téléphone ; le conteneur est en UTC)."""
    import datetime
    ts = time.time() if ts is None else ts
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.fromtimestamp(ts, ZoneInfo((s or alert_settings())["tz"]))
    except Exception:  # noqa: BLE001 — fuseau inconnu ou tzdata absent : heure du conteneur
        return datetime.datetime.fromtimestamp(ts)


def local_now(s=None):
    return local_time(None, s)


def alert_settings():
    return {**ALERT_DEFAULTS, **read_json(ALERTS_FILE, {}).get("settings", {})}


def r_push_info(_):
    if not PUSH_OK:
        return {"available": False}
    return {"available": True, "key": b64u(raw_pub(vapid_key())), "devices": len(read_json(PUSH_FILE, [])),
            "settings": alert_settings()}


def r_push_subscribe(d):
    if not PUSH_OK:
        raise ApiError(503, "Notifications indisponibles : mets à jour PVE Hub depuis le Shell de Proxmox")
    sub = d.get("subscription") or {}
    endpoint, keys = str(sub.get("endpoint", "")), sub.get("keys") or {}
    if not endpoint.startswith("https://") or len(endpoint) > 1000 or not keys.get("p256dh") or not keys.get("auth"):
        raise ApiError(400, "Abonnement invalide")
    with _push_lock:
        subs = [s for s in read_json(PUSH_FILE, []) if s["endpoint"] != endpoint]
        subs.append({"endpoint": endpoint, "keys": {"p256dh": str(keys["p256dh"]), "auth": str(keys["auth"])},
                     "name": str(d.get("name", ""))[:60], "at": int(time.time())})
        write_json(PUSH_FILE, subs)
    return {"ok": True, "devices": len(subs)}


def r_push_unsubscribe(d):
    with _push_lock:
        subs = [s for s in read_json(PUSH_FILE, []) if s["endpoint"] != d.get("endpoint")]
        write_json(PUSH_FILE, subs)
    return {"ok": True, "devices": len(subs)}


def r_push_test(_):
    n = send_push("PVE Hub", "Les notifications fonctionnent ✓", tag="test")
    if not n:
        raise ApiError(502, "Aucune notification envoyée : active-les d'abord sur cet appareil (voir le journal en cas d'erreur)")
    return {"sent": n}


def r_alert_settings(d):
    s = alert_settings()
    for k in ("stopped", "disk", "backup", "updates", "report", "apps", "smart"):
        if k in d:
            s[k] = bool(d[k])
    if "report_time" in d:
        if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", str(d["report_time"])):
            raise ApiError(400, "Heure invalide")
        s["report_time"] = d["report_time"]
    if "tz" in d:
        tz = str(d["tz"])
        try:
            from zoneinfo import ZoneInfo
            ZoneInfo(tz)
            s["tz"] = tz
        except Exception:  # noqa: BLE001 — tzdata absent ou nom inconnu : on garde l'ancien
            pass
    if "disk_threshold" in d:
        try:
            s["disk_threshold"] = max(50, min(99, int(d["disk_threshold"])))
        except (TypeError, ValueError):
            raise ApiError(400, "Seuil invalide")
    with _push_lock:  # la surveillance écrit aussi dans ce fichier (clé "state")
        cur = read_json(ALERTS_FILE, {})
        cur["settings"] = s
        write_json(ALERTS_FILE, cur)
    return {"settings": s}


# ---------------------------------------------------------------- surveillance (alertes)
# Tâches Proxmox qui arrêtent une machine volontairement : si l'une d'elles est récente, l'arrêt n'est pas une panne
STOP_TASKS = {"qmstop", "qmshutdown", "qmreboot", "qmsuspend", "qmpause", "qmhibernate", "qmigrate", "qmrestore",
              "qmrollback", "qmdestroy", "vzstop", "vzshutdown", "vzreboot", "vzsuspend", "vzmigrate", "vzrestore",
              "vzrollback", "vzdestroy", "vzdump"}


def gname(g):
    return f"{'VM' if g.get('type') == 'qemu' else 'CT'} {g.get('vmid')}" + (f" « {g['name']} »" if g.get("name") else "")


def check_stopped(prev, guests, tasks, now):
    """Machines passées de « running » à « stopped » sans tâche d'arrêt récente (panne, OOM…)."""
    backup_running = any(t.get("type") == "vzdump" and (not t.get("endtime") or now - t["starttime"] < 900) for t in tasks)
    alerts = []
    for g in guests:
        if prev.get(g["id"]) != "running" or g.get("status") != "stopped":
            continue
        asked = any(t.get("type") in STOP_TASKS and str(t.get("id")) == str(g["vmid"]) and now - t.get("starttime", 0) < 900
                    for t in tasks)
        if not asked and not backup_running:  # une sauvegarde en mode « stop » arrête les machines un moment
            alerts.append(("Machine arrêtée", f"{gname(g)} s'est arrêtée sans qu'aucun arrêt n'ait été demandé.", f"/#g={g['id']}"))
    return alerts


def check_disk(items, threshold, alerted, now):
    """items : [(clé, libellé, utilisé, total)]. Alerte au franchissement du seuil, rappel toutes les 24 h, réarmement sous seuil-5."""
    alerts = []
    for key, label, used, total in items:
        if not total:
            continue
        p = 100 * used / total
        if p >= threshold and now - alerted.get(key, 0) > 86400:
            alerted[key] = now
            alerts.append(("Espace disque", f"{label} est plein à {p:.0f} % ({fmt_bytes(used)} sur {fmt_bytes(total)}).", "/"))
        elif p < threshold - 5:
            alerted.pop(key, None)
    return alerts


def check_failed_backups(tasks, since):
    """Sauvegardes terminées en erreur depuis le dernier passage. Retourne (alertes, nouveau repère)."""
    done = [t for t in tasks if t.get("type") == "vzdump" and t.get("endtime") and t["endtime"] > since]
    bad = [t for t in done if t.get("status") != "OK"]
    alerts = [("Sauvegarde en échec", f"Sauvegarde{' de la machine ' + str(t['id']) if t.get('id') else ''} du "
               f"{local_time(t['starttime']).strftime('%d/%m à %H:%M')} : {t.get('status')}", "/#maint") for t in bad]
    return alerts, max([since] + [t["endtime"] for t in done])


def check_late_backups(rows, now):
    """Machines incluses dans une sauvegarde planifiée dont la dernière sauvegarde a plus de 7 jours (ou aucune)."""
    late = [r for r in rows if r["planned"] and (not r["last"] or now - r["last"]["ctime"] > 7 * 86400)]
    if not late:
        return []
    names = ", ".join(r["name"] or str(r["vmid"]) for r in late[:5]) + ("…" if len(late) > 5 else "")
    return [("Sauvegardes en retard", f"Pas de sauvegarde depuis plus de 7 jours : {names}.", "/#maint")]


def check_apps(prev, apps):
    """Apps de l'onglet Apps qui répondaient et ne répondent plus (2 vérifications de suite, contre les faux positifs).
    prev : {id: {"up_seen", "fails", "down"}} mis à jour sur place. Retourne (alertes, apps revenues)."""
    alerts, back, ids = [], [], set()
    for a in apps:
        if a.get("hidden") or a.get("up") not in (True, False):
            continue
        ids.add(a["id"])
        st = prev.setdefault(a["id"], {"up_seen": False, "fails": 0, "down": False})
        if a["up"]:
            if st["down"]:
                back.append(a["name"])
            st.update(up_seen=True, fails=0, down=False)
        else:
            st["fails"] += 1
            if st["fails"] >= 2 and st["up_seen"] and not st["down"]:  # jamais vue en ligne : pas une panne, juste une adresse morte
                st["down"] = True
                alerts.append(("App hors ligne", f"{a['name']} ne répond plus ({a['url']}).", "/#apps"))
    for k in [k for k in prev if k not in ids]:
        del prev[k]  # machine arrêtée ou app masquée : l'alerte « machine arrêtée » prend le relais
    return alerts, back


# ---------------------------------------------------------------- santé des disques physiques (SMART, via l'API Proxmox)
TEMP_MAX = {"hdd": 55}  # au-delà : alerte ; SSD et NVMe supportent plus chaud
TEMP_MAX_DEFAULT = 70


def parse_smart_temp(sm):
    """Température (°C) depuis /disks/smart : attribut 194/190 (SATA) ou ligne « Temperature: N Celsius » (NVMe)."""
    for a in sm.get("attributes") or []:
        if str(a.get("id")) in ("194", "190") or "temperature" in str(a.get("name", "")).lower():
            m = re.match(r"\d+", str(a.get("raw", "")).strip())
            if m:
                return int(m.group())
    m = re.search(r"Temperature:\s+(\d+)\s*Celsius", sm.get("text") or "")
    return int(m.group(1)) if m else None


def node_disks(node):
    disks = [{"node": node, "dev": d.get("devpath", ""), "model": (d.get("model") or d.get("vendor") or "Disque").strip(),
              "size": d.get("size", 0), "type": d.get("type") or "unknown", "health": str(d.get("health") or "UNKNOWN").upper(),
              "wearout": d["wearout"] if isinstance(d.get("wearout"), (int, float)) else None, "used": d.get("used") or ""}
             for d in pve("GET", f"/nodes/{node}/disks/list") or [] if d.get("devpath")]

    def temp(d):
        try:
            return parse_smart_temp(pve("GET", f"/nodes/{node}/disks/smart", {"disk": d["dev"]}, timeout=20) or {})
        except ApiError:
            return None
    with ThreadPoolExecutor(4) as ex:
        for d, t in zip(disks, ex.map(temp, disks)):
            d["temp"] = t
    return disks


def r_disks(_):
    out, errors = [], []
    for n in pve("GET", "/nodes") or []:
        if n.get("status") == "online":
            try:
                out += node_disks(n["node"])
            except ApiError as e:
                errors.append(f"{n['node']} : {e.msg}")
    return {"disks": out, "error": "; ".join(errors) or None, "limits": {**TEMP_MAX, "other": TEMP_MAX_DEFAULT}}


def disk_problems(d):
    """Liste des problèmes d'un disque (vide si tout va bien). wearout = % d'usure (SSD), comme dans Proxmox."""
    p = []
    if d["health"] not in ("PASSED", "OK", "UNKNOWN", ""):
        p.append(f"état SMART « {d['health']} »")
    if d.get("wearout") is not None and d["wearout"] >= 90:
        p.append(f"usé à {d['wearout']:.0f} %")
    lim = TEMP_MAX.get(d["type"], TEMP_MAX_DEFAULT)
    if d.get("temp") is not None and d["temp"] >= lim:
        p.append(f"{d['temp']} °C (max conseillé {lim} °C)")
    return p


def check_disks(disks, alerted, now):
    """Une alerte par disque en difficulté, rappel au plus une fois par jour ; réarmée quand il va mieux."""
    alerts = []
    for d in disks:
        key, p = f"{d['node']}:{d['dev']}", disk_problems(d)
        if not p:
            alerted.pop(key, None)
        elif now - alerted.get(key, 0) > 86400:
            alerted[key] = now
            alerts.append(("Santé d'un disque", f"{d['model']} ({d['dev']}) : {', '.join(p)}. Pense à sauvegarder.", "/#maint"))
    return alerts


# ---------------------------------------------------------------- horaires : allumer / éteindre une machine à heure fixe
SCHED_FILE = os.path.join(DATA_DIR, "schedules.json")
SCHED_DAYS = {"all": range(7), "week": range(5), "weekend": (5, 6)}  # 0 = lundi
_sched_lock = threading.Lock()


def sched_norm(it):
    """Ancien format (une machine : node/type/vmid) → liste « targets »."""
    if "targets" not in it:
        it = {**it, "targets": [{"node": it.pop("node", ""), "type": it.pop("type"), "vmid": it.pop("vmid")}]}
    return it


def load_sched():
    return [sched_norm(it) for it in read_json(SCHED_FILE, [])]


def r_schedules(_):
    return {"items": load_sched()}


def sched_fields(d):
    """Champs validés d'un horaire : action, heure, jours, machines (1 à 50)."""
    if d.get("action") not in ("start", "shutdown"):
        raise ApiError(400, "Action invalide")
    if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", str(d.get("time", ""))):
        raise ApiError(400, "Heure invalide")
    if d.get("days") not in SCHED_DAYS:
        raise ApiError(400, "Jours invalides")
    raw = d.get("targets") if isinstance(d.get("targets"), list) else [d]
    targets, seen = [], set()
    for t in raw[:50]:
        node, typ, vmid = guest_args(t if isinstance(t, dict) else {})
        if (typ, vmid) not in seen:
            seen.add((typ, vmid))
            targets.append({"node": node, "type": typ, "vmid": vmid})
    if not targets:
        raise ApiError(400, "Choisis au moins une machine")
    return {"action": d["action"], "time": d["time"], "days": d["days"], "targets": targets}


def r_schedules_save(d):
    with _sched_lock:
        items = load_sched()
        op, sid = d.get("op"), str(d.get("id", ""))
        if op == "add":
            items.append({"id": secrets.token_hex(4), **sched_fields(d), "enabled": True})
        elif op == "update":
            f = sched_fields(d)
            items = [{**it, **f} if it["id"] == sid else it for it in items]
        elif op == "toggle":
            for it in items:
                if it["id"] == sid:
                    it["enabled"] = not it["enabled"]
        elif op == "delete":
            items = [it for it in items if it["id"] != sid]
        elif op == "remove_target":  # retirer une machine d'un horaire (l'horaire disparaît s'il n'en reste aucune)
            vmid, typ = int(d.get("vmid") or 0), d.get("type")
            for it in items:
                if it["id"] == sid:
                    it["targets"] = [t for t in it["targets"] if not (t["vmid"] == vmid and t["type"] == typ)]
            items = [it for it in items if it["targets"]]
        else:
            raise ApiError(400, "Demande invalide")
        if op in ("add", "update") and d.get("tz"):  # l'heure saisie est celle du téléphone : le serveur, lui, est en UTC
            r_alert_settings({"tz": d["tz"]})
        write_json(SCHED_FILE, items)
    return {"items": items}


def due_schedules(items, ln, done):
    """Horaires à exécuter maintenant (heure locale ln) : l'heure est passée de moins de 10 min et pas encore faits aujourd'hui.
    done : {id: "AAAA-MM-JJ"} mis à jour sur place."""
    today, out = ln.strftime("%Y-%m-%d"), []
    for it in items:
        h, m = map(int, it["time"].split(":"))
        late = (ln.hour * 60 + ln.minute) - (h * 60 + m)
        if it.get("enabled") and ln.weekday() in SCHED_DAYS.get(it["days"], ()) and 0 <= late < 10 and done.get(it["id"]) != today:
            done[it["id"]] = today
            out.append(it)
    return out


def run_schedule(it, guests):
    """Allume ou éteint chaque machine de l'horaire (dans l'ordre) ; une ligne au Journal, plus une alerte par échec."""
    it = sched_norm(dict(it))
    verb = "Allumage" if it["action"] == "start" else "Extinction"
    done = []
    for t in it["targets"]:
        g = next((g for g in guests if g["vmid"] == t["vmid"] and g["type"] == t["type"]), None)
        label = gname(g) if g else f"{'VM' if t['type'] == 'qemu' else 'CT'} {t['vmid']}"
        if not g:
            log_event("alert", f"{verb} programmé impossible", f"{label} n'existe plus")
            continue
        if (it["action"] == "start") == (g.get("status") == "running"):
            continue  # déjà dans l'état voulu
        try:
            pve("POST", f"/nodes/{g['node']}/{t['type']}/{t['vmid']}/status/{it['action']}")
            done.append(label)
        except ApiError as e:
            log_event("alert", f"{verb} programmé en échec : {label}", e.msg, f"/#g={t['type']}/{t['vmid']}")
    if done:
        title = f"{verb} programmé : {done[0]}" if len(done) == 1 else f"{verb} programmé : {len(done)} machines"
        log_event("update", title, f"Horaire de {it['time']}" + ("" if len(done) == 1 else " — " + ", ".join(done)), "/#sched")


def disk_items(nodes, storages, guests):
    items = [(f"node:{n['node']}", f"Le disque système de {n['node']}", n.get("disk", 0), n.get("maxdisk", 0)) for n in nodes]
    items += [(f"st:{s['node']}:{s['storage']}", f"Le stockage {s['storage']}", s.get("disk", 0), s.get("maxdisk", 0))
              for s in storages if s.get("status") == "available"]
    # disque des conteneurs (Proxmox ne connaît pas l'occupation réelle du disque d'une VM)
    items += [(f"ct:{g['vmid']}", f"Le disque de {gname(g)}", g.get("disk", 0), g.get("maxdisk", 0))
              for g in guests if g.get("type") == "lxc" and g.get("status") == "running"]
    return items


def monitor_loop():
    ctx = {"prev": {}, "first": True}
    while True:
        try:
            monitor_once(ctx)
        except Exception as e:  # noqa: BLE001 — la surveillance ne doit jamais s'arrêter
            print("Surveillance :", repr(e), file=sys.stderr)
        time.sleep(60)


def monitor_once(ctx):
    """Un passage de surveillance ; ctx garde l'état des machines entre deux passages."""
    now = int(time.time())
    s = alert_settings()
    with _push_lock:
        # valeurs par défaut fusionnées : un état ancien ou partiel ne doit pas faire planter la surveillance
        state = {"disk": {}, "failed_end": now, "updates_sent": now, **(read_json(ALERTS_FILE, {}).get("state") or {})}
    before = json.dumps(state, sort_keys=True)
    guests = [g for g in pve("GET", "/cluster/resources", {"type": "vm"}) or [] if not g.get("template")]
    tasks = pve("GET", "/cluster/tasks") or []
    alerts = []
    if s["stopped"] and not ctx["first"]:
        alerts += check_stopped(ctx["prev"], guests, tasks, now)
    ctx["prev"], ctx["first"] = {g["id"]: g.get("status") for g in guests}, False
    if s["disk"]:
        nodes = pve("GET", "/nodes") or []
        storages = pve("GET", "/cluster/resources", {"type": "storage"}) or []
        alerts += check_disk(disk_items(nodes, storages, guests), s["disk_threshold"], state["disk"], now)
    # horaires d'allumage / d'extinction (un arrêt programmé passe par « shutdown » : pas d'alerte « machine arrêtée »)
    items = load_sched()
    if items:
        for it in due_schedules(items, local_now(s), state.setdefault("sched_done", {})):
            run_schedule(it, guests)
    # apps de l'onglet Apps : toutes les 5 minutes (balayage des ports par SSH)
    if s["apps"] and now - ctx.get("apps_at", 0) >= 290:
        ctx["apps_at"] = now
        try:
            a, back = check_apps(ctx.setdefault("apps", {}), r_apps({})["apps"])
            alerts += a
            for name in back:
                log_event("alert", f"{name} répond à nouveau", url="/#apps")
        except ApiError:
            pass
    # disques physiques : toutes les 6 h (interroger SMART trop souvent réveille les disques en veille)
    if s["smart"] and now - state.get("smart_at", 0) >= 6 * 3600:
        state["smart_at"] = now
        try:
            alerts += check_disks(r_disks({})["disks"], state.setdefault("smart", {}), now)
        except ApiError:
            pass
    a, state["failed_end"] = check_failed_backups(tasks, state.get("failed_end", now))
    alerts += a if s["backup"] else []
    # une fois par jour, en matinée : machines couvertes par une sauvegarde planifiée mais pas sauvegardées depuis 7 jours
    ln = local_now(s)
    today = ln.strftime("%Y-%m-%d")
    if s["backup"] and state.get("late_day") != today and ln.hour >= 9:
        state["late_day"] = today
        alerts += check_late_backups(r_maint_backups({})["guests"], now)
    # résumé hebdomadaire des mises à jour, en matinée
    if s["updates"] and EXEC_ENABLED and now - state.get("updates_sent", now) > 7 * 86400 and ln.hour >= 9:
        state["updates_sent"] = now
        scan_updates()
        cts = [c for c in _updates["cts"].values() if c["packages"]]
        host = len((_updates.get("host") or {}).get("packages", []))
        if cts or host:
            parts = [f"{len(cts)} machine{'s' if len(cts) > 1 else ''} ({sum(len(c['packages']) for c in cts)} paquets)"] if cts else []
            parts += [f"l'hôte ({host} paquets)"] if host else []
            alerts.append(("Mises à jour disponibles", " et ".join(parts) + " à mettre à jour.", "/#maint"))
    for title, body, url in alerts:
        send_push(title, body, url, tag=title)
        log_event("alert", title, body, url)
    state["log"] = (state.get("log", []) + [{"ts": now, "title": t, "body": b} for t, b, _ in alerts])[-50:]
    # rapport du matin, rédigé en arrière-plan (Hermes peut mettre une minute)
    if s["report"] and state.get("report_day") != today and ln.strftime("%H:%M") >= s["report_time"]:
        state["report_day"] = today
        threading.Thread(target=generate_report, daemon=True).start()
    if json.dumps(state, sort_keys=True) != before:
        with _push_lock:
            cur = read_json(ALERTS_FILE, {})
            cur["state"] = state
            write_json(ALERTS_FILE, cur)
    return alerts


# ---------------------------------------------------------------- store : catalogue
CS_REPO = "community-scripts/ProxmoxVE"
CS_TARBALL = f"https://codeload.github.com/{CS_REPO}/tar.gz/refs/heads/main"
CATALOG_FILE = os.path.join(DATA_DIR, "catalog.json")
_catalog = {"building": False, "error": None}
RE_SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,60}$")


def parse_cs_header(slug, text):
    """Métadonnées d'un script communautaire depuis son en-tête (APP, var_tags, ressources, # Source)."""
    def var(name):
        m = re.search(rf'^\s*{name}="(?:\$\{{{name}:-)?([^"}}]*)\}}?"', text, re.M)  # indenté si dépend de l'OS choisi
        return m.group(1) if m else ""
    app = var("APP")
    if not app:
        return None
    src = re.search(r"^# Source:\s*(https?://\S+)", text, re.M)
    num = lambda n: int(var(n)) if var(n).isdigit() else None
    return {"id": slug, "name": app, "tags": [t for t in var("var_tags").split(";") if t][:4],
            "cpu": num("var_cpu"), "ram": num("var_ram"), "disk": num("var_disk"),
            "os": " ".join(x for x in (var("var_os"), var("var_version")) if x), "site": src.group(1) if src else None}


def build_catalog():
    """Télécharge l'archive des scripts (une fois par semaine) et lit l'en-tête de chaque ct/*.sh."""
    import tarfile
    try:
        req = urllib.request.Request(CS_TARBALL, headers={"User-Agent": "PVEHub"})
        items = []
        with urllib.request.urlopen(req, timeout=120) as r, tarfile.open(fileobj=r, mode="r|gz") as tar:
            for m in tar:  # lecture en flux : seuls les petits fichiers ct/<slug>.sh sont décompressés
                parts = m.name.split("/")
                if m.isfile() and len(parts) == 3 and parts[1] == "ct" and parts[2].endswith(".sh") and m.size < 200_000:
                    slug = parts[2][:-3]
                    if RE_SLUG.match(slug):
                        it = parse_cs_header(slug, tar.extractfile(m).read().decode("utf-8", "replace"))
                        if it:
                            items.append(it)
        items.sort(key=lambda x: x["name"].lower())
        write_json(CATALOG_FILE, {"at": int(time.time()), "items": items})
        _catalog["error"] = None
    except Exception as e:  # noqa: BLE001 — réseau, archive… : l'écran affiche l'erreur
        _catalog["error"] = f"Catalogue injoignable : {getattr(e, 'reason', e)}"
    finally:
        _catalog["building"] = False


def community_catalog(refresh=False):
    cat = read_json(CATALOG_FILE, {})
    if (refresh or not cat or time.time() - cat.get("at", 0) > 7 * 86400) and not _catalog["building"]:
        _catalog["building"] = True
        threading.Thread(target=build_catalog, daemon=True).start()
    return cat


def turnkey_catalog(node):
    items = []
    for a in pve("GET", f"/nodes/{node}/aplinfo") or []:
        if a.get("section") == "turnkeylinux" and a.get("template"):
            name = re.sub(r"^TurnKey\s+", "", a.get("headline") or a.get("package", ""))
            items.append({"id": a["template"], "name": name, "desc": a.get("description", ""), "site": a.get("infopage"),
                          "os": a.get("os", ""), "version": a.get("version", ""), "tags": ["officiel"]})
    return sorted(items, key=lambda x: x["name"].lower())


def r_store(q):
    node = q.get("node") or (pve("GET", "/nodes") or [{}])[0].get("node")
    if q.get("source") == "turnkey":
        if not RE_NODE.match(node or ""):
            raise ApiError(400, "Nœud invalide")
        return {"items": turnkey_catalog(node)}
    cat = community_catalog(bool(q.get("refresh")))
    return {"items": cat.get("items", []), "at": cat.get("at"), "building": _catalog["building"], "error": _catalog["error"],
            "exec": EXEC_ENABLED}


def r_store_options(_):
    """Valeurs proposées à l'installation : nœuds, stockages (disques / modèles), ponts réseau."""
    out = []
    for n in pve("GET", "/nodes") or []:
        if n.get("status") != "online":
            continue
        st = pve("GET", f"/nodes/{n['node']}/storage", {"enabled": 1}) or []
        bridges = [b["iface"] for b in pve("GET", f"/nodes/{n['node']}/network", {"type": "any_bridge"}) or [] if b.get("iface")]
        out.append({"node": n["node"], "bridges": sorted(bridges) or ["vmbr0"],
                    "rootdir": [s["storage"] for s in st if "rootdir" in (s.get("content") or "") and s.get("active", 1)],
                    "vztmpl": [s["storage"] for s in st if "vztmpl" in (s.get("content") or "") and s.get("active", 1)]})
    return {"nodes": out}


# ---------------------------------------------------------------- store : installation
_store_jobs = {}
RE_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]")


def wait_pve_task(node, upid, timeout=1800):
    for _ in range(timeout // 2):
        st = pve("GET", f"/nodes/{node}/tasks/{urllib.parse.quote(upid, safe='')}/status") or {}
        if st.get("status") == "stopped":
            return st.get("exitstatus")
        time.sleep(2)
    return "délai dépassé"


def job_log(job, line):
    # couleurs et animations retirées ; une ligne réécrite par « \r » garde son dernier texte non vide
    parts = [p.strip() for p in RE_ANSI.sub("", line).rstrip("\n").split("\r") if p.strip()]
    if not parts:
        return
    line = parts[-1]
    job["log"] = (job["log"] + [line])[-300:]
    m = re.search(r"(https?://\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\S*)", line)
    if m and "github" not in line:
        job["url"] = m.group(1)
    m = re.search(r"(?:Container ID|CT ID|CTID)\D{0,5}(\d{3,9})", line, re.I)
    if m:
        job["vmid"] = int(m.group(1))


def install_community(job, slug, store, tstore, bridge):
    url = f"https://raw.githubusercontent.com/{CS_REPO}/main/ct/{slug}.sh"
    # mode=default + PHS_SILENT=1 : « installation par défaut », sans question ; les menus whiptail sont aussi
    # évités faute de vrai terminal (stdin fermé). TERM=xterm et non « dumb » : le script commence par « clear »,
    # qui échoue avec TERM=dumb et arrête tout (code 1).
    script = (f"export TERM=xterm-256color PHS_SILENT=1 mode=default var_container_storage={store} "
              f"var_template_storage={tstore} var_brg={bridge}; bash -c \"$(curl -fsSL {url})\"")
    job_log(job, f"$ {script}")
    started = int(time.time())
    code = run_ssh_stream(f"bash -c {shlex.quote(script)}", lambda l: job_log(job, l), timeout=2700)
    if code != 0:
        # le script écrit un journal détaillé sur l'hôte : on en montre la fin pour voir la vraie cause
        _c, out = run_ssh(f"f=$(find /tmp -maxdepth 1 -name 'build-*.log' -newermt @{started - 5} 2>/dev/null | sort | tail -1); "
                          "[ -n \"$f\" ] && echo \"— fin de $f —\" && tail -n 25 \"$f\"", timeout=15)
        for l in out.splitlines():
            job_log(job, l)
        raise ApiError(502, f"Le script s'est arrêté avec le code {code}")


def install_turnkey(job, node, template, name, store, tstore, bridge):
    have = [c.get("volid", "") for c in pve("GET", f"/nodes/{node}/storage/{tstore}/content", {"content": "vztmpl"}) or []]
    if not any(v.endswith("/" + template) for v in have):
        job_log(job, f"Téléchargement du modèle {template}…")
        try:
            st = wait_pve_task(node, pve("POST", f"/nodes/{node}/aplinfo", {"storage": tstore, "template": template}))
        except ApiError as e:
            # droit Datastore.AllocateTemplate absent (installation pas encore mise à jour) : root s'en charge via SSH
            if "permission" not in e.msg.lower() or not EXEC_ENABLED:
                raise
            job_log(job, "Droit manquant pour l'API, téléchargement via SSH…")
            code, out = run_ssh(f"pveam update >/dev/null; pveam download {shlex.quote(tstore)} {shlex.quote(template)}", timeout=900)
            st = "OK" if code == 0 else out.strip()[-300:] or f"code {code}"
        if st != "OK":
            raise ApiError(502, f"Téléchargement du modèle : {st}")
    vmid = int(pve("GET", "/cluster/nextid"))
    password = "".join(secrets.choice("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(16))
    params = {"vmid": vmid, "ostemplate": f"{tstore}:vztmpl/{template}", "password": password,
              "hostname": re.sub(r"[^a-z0-9-]", "-", name.lower()).strip("-")[:40] or f"ct{vmid}",
              "cores": 2, "memory": 1024, "swap": 512, "rootfs": f"{store}:8", "unprivileged": 1, "features": "nesting=1",
              "net0": f"name=eth0,bridge={bridge},ip=dhcp", "start": 1, "description": f"{name} (TurnKey) — installé par PVE Hub"}
    job_log(job, f"Création du conteneur {vmid} ({name})…")
    try:
        upid = pve("POST", f"/nodes/{node}/lxc", params)
    except ApiError as e:
        if "feature" not in e.msg.lower() and "nesting" not in e.msg.lower():
            raise
        job_log(job, "Option nesting refusée, création sans.")  # selon la version, seul root@pam peut la régler
        upid = pve("POST", f"/nodes/{node}/lxc", {k: v for k, v in params.items() if k != "features"})
    st = wait_pve_task(node, upid)
    if st != "OK":
        raise ApiError(502, f"Création du conteneur : {st}")
    job.update(vmid=vmid, password=password)
    job_log(job, f"Conteneur {vmid} créé et démarré.")


INSTALLED_FILE = os.path.join(DATA_DIR, "installed.json")  # {vmid: {name, source, url, at}} : apps posées par le Store
_installed_lock = threading.Lock()


def all_guests():
    return [g for g in pve("GET", "/cluster/resources", {"type": "vm"}) or [] if not g.get("template")]


def same_guest(entry, g):
    """L'app notée est-elle toujours cette machine ? Proxmox réutilise les ID libérés : le nom doit aussi correspondre."""
    return bool(g) and (not entry.get("guest") or entry["guest"] == g.get("name", ""))


def remember_install(job, before):
    """Retrouve le conteneur créé (ID lu dans le journal, sinon le seul nouveau) et le note pour l'onglet Apps."""
    new = [g["vmid"] for g in all_guests() if g["vmid"] not in before]
    vmid = job.get("vmid") or (new[0] if len(new) == 1 else None)
    if not vmid:
        return
    job["vmid"] = vmid
    gname_ = next((g.get("name", "") for g in all_guests() if g["vmid"] == vmid), "")
    with _installed_lock:
        inst = read_json(INSTALLED_FILE, {})
        inst[str(vmid)] = {"name": job["name"], "source": job["source"], "url": job.get("url"), "at": int(time.time()),
                           "guest": gname_}
        write_json(INSTALLED_FILE, inst)


REMOVED_FILE = os.path.join(DATA_DIR, "removed.json")  # apps désinstallées avec sauvegarde : réinstallables


def newest_backup(node, vmid):
    """volid de la sauvegarde la plus récente d'une machine, tous stockages de sauvegarde confondus."""
    items = []
    for st in backup_storages(node):
        try:
            got = pve("GET", f"/nodes/{node}/storage/{st}/content", {"content": "backup", "vmid": vmid})
            items += got if isinstance(got, list) else []
        except ApiError:
            pass
    items.sort(key=lambda i: i.get("ctime", 0))
    return items[-1] if items else None


def uninstall(job, vmid, backup):
    g = next((g for g in all_guests() if g["vmid"] == vmid), None)
    if not g:
        raise ApiError(404, f"La machine {vmid} n'existe plus")
    entry = read_json(INSTALLED_FILE, {}).get(str(vmid), {})
    if not same_guest(entry, g):
        raise ApiError(409, f"La machine {vmid} n'est plus celle installée par le Store : rien n'a été supprimé")
    node, typ = g["node"], g["type"]
    cfg = pve("GET", f"/nodes/{node}/{typ}/{vmid}/config")
    rootfs_store = str((cfg if isinstance(cfg, dict) else {}).get("rootfs") or "").split(":", 1)[0] or None
    bk = None
    if backup:
        storage = (backup_storages(node) or [None])[0]
        if not storage:
            raise ApiError(409, "Aucun stockage de sauvegarde : choisis « Supprimer sans sauvegarde »")
        job_log(job, f"Sauvegarde de {vmid} sur {storage}…")
        st = wait_pve_task(node, pve("POST", f"/nodes/{node}/vzdump", {"vmid": vmid, "storage": storage, "mode": "snapshot",
                                     "compress": "zstd", "notes-template": f"{job['name']} — avant désinstallation (PVE Hub)"}))
        if st != "OK":
            raise ApiError(502, f"Sauvegarde : {st} — rien n'a été supprimé")
        bk = newest_backup(node, vmid)
    if g.get("status") == "running":
        job_log(job, "Arrêt…")
        st = wait_pve_task(node, pve("POST", f"/nodes/{node}/{typ}/{vmid}/status/stop"))
        if st != "OK":
            raise ApiError(502, f"Arrêt : {st}")
    job_log(job, "Suppression du conteneur et de ses disques…")
    # purge : le retire aussi des tâches de sauvegarde et de la réplication
    st = wait_pve_task(node, pve("DELETE", f"/nodes/{node}/{typ}/{vmid}?purge=1&destroy-unreferenced-disks=1"))
    if st != "OK":
        raise ApiError(502, f"Suppression : {st}")
    with _installed_lock:
        inst = read_json(INSTALLED_FILE, {})
        inst.pop(str(vmid), None)
        write_json(INSTALLED_FILE, inst)
        if bk and bk.get("volid"):
            removed = [r for r in read_json(REMOVED_FILE, []) if r["volid"] != bk["volid"]]
            removed.append({"id": secrets.token_hex(4), "name": job["name"], "source": entry.get("source", ""), "url": entry.get("url"),
                            "node": node, "vmid": vmid, "storage": rootfs_store, "volid": bk["volid"], "ctime": bk.get("ctime", 0),
                            "at": int(time.time())})
            write_json(REMOVED_FILE, removed[-20:])


def restore_app(job, rid):
    """Recrée le conteneur depuis la sauvegarde faite à la désinstallation, le démarre et le remet dans l'onglet Apps."""
    r = next((x for x in read_json(REMOVED_FILE, []) if x["id"] == rid), None)
    if not r:
        raise ApiError(404, "App inconnue")
    node = r["node"]
    if not any(b.get("volid") == r["volid"] for b in
               pve("GET", f"/nodes/{node}/storage/{r['volid'].split(':', 1)[0]}/content", {"content": "backup", "vmid": r["vmid"]}) or []):
        raise ApiError(404, "La sauvegarde n'existe plus (supprimée ou effacée par la rotation des sauvegardes)")
    used = {g["vmid"] for g in all_guests()}
    vmid = r["vmid"] if r["vmid"] not in used else int(pve("GET", "/cluster/nextid"))
    job_log(job, f"Restauration de la sauvegarde dans le conteneur {vmid}…")
    # stockage d'origine, sinon le premier qui accepte des conteneurs ; le reste de la configuration vient de la sauvegarde
    storage = r.get("storage") or next((x["storage"] for x in pve("GET", f"/nodes/{node}/storage", {"enabled": 1}) or []
                                        if "rootdir" in (x.get("content") or "")), None)
    params = {"vmid": vmid, "ostemplate": r["volid"], "restore": 1, "storage": storage}
    st = wait_pve_task(node, pve("POST", f"/nodes/{node}/lxc", params))
    if st != "OK":
        raise ApiError(502, f"Restauration : {st}")
    job_log(job, "Démarrage…")
    wait_pve_task(node, pve("POST", f"/nodes/{node}/lxc/{vmid}/status/start"))
    job.update(vmid=vmid, url=r.get("url"))
    remember_install(job, set())
    with _installed_lock:
        write_json(REMOVED_FILE, [x for x in read_json(REMOVED_FILE, []) if x["id"] != rid])


def r_store_removed(_):
    return {"items": sorted(read_json(REMOVED_FILE, []), key=lambda r: -r["at"])}


def r_store_restore(d):
    rid = str(d.get("id", ""))
    r = next((x for x in read_json(REMOVED_FILE, []) if x["id"] == rid), None)
    if not r:
        raise ApiError(404, "App inconnue")
    if d.get("forget"):  # retirer de la liste : la sauvegarde, elle, reste sur le stockage
        with _installed_lock:
            write_json(REMOVED_FILE, [x for x in read_json(REMOVED_FILE, []) if x["id"] != rid])
        return {"ok": True}
    if any(j.get("rid") == rid and j["status"] == "running" for j in list(_store_jobs.values())):
        raise ApiError(409, "Réinstallation déjà en cours")
    job_id = secrets.token_hex(6)
    _store_jobs[job_id] = job = {"id": job_id, "kind": "restore", "rid": rid, "source": r["source"], "name": r["name"],
                                 "status": "running", "at": int(time.time()), "log": []}
    threading.Thread(target=run_store_job, args=(job, "restore", rid), daemon=True).start()
    return {"job": job_id}


def run_store_job(job, kind, *args):
    try:
        if kind == "uninstall":
            uninstall(job, *args)
        elif kind == "restore":
            restore_app(job, *args)
        else:
            before = {g["vmid"] for g in all_guests()}
            (install_community if kind == "community" else install_turnkey)(job, *args)
            remember_install(job, before)
        job["status"] = "done"
    except ApiError as e:
        job.update(status="error", error=e.msg)
    except Exception as e:  # noqa: BLE001
        job.update(status="error", error=str(e)[:200])
    job_log(job, "✓ Terminé" if job["status"] == "done" else f"✕ {job.get('error')}")
    verb = {"uninstall": "désinstallé", "restore": "réinstallé"}.get(kind, "installé")
    log_event("store", f"{job['name']} {verb}" if job["status"] == "done" else f"{job['name']} : échec",
              job.get("error") or (f"Conteneur {job['vmid']}" if job.get("vmid") else ""))


def r_store_install(d):
    source, item_id = d.get("source"), str(d.get("id", ""))
    node, store, tstore, bridge = str(d.get("node", "")), str(d.get("storage", "")), str(d.get("tstorage", "")), str(d.get("bridge", ""))
    if not RE_NODE.match(node) or not RE_STORE.match(store) or not RE_STORE.match(tstore) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,30}", bridge):
        raise ApiError(400, "Nœud, stockage ou pont invalide")
    if source == "community":
        if not EXEC_ENABLED:
            raise ApiError(403, "Active la section Commandes pour installer des scripts communautaires")
        item = next((i for i in read_json(CATALOG_FILE, {}).get("items", []) if i["id"] == item_id), None)
        if not item or not RE_SLUG.match(item_id):
            raise ApiError(404, "Script inconnu")
        args = ("community", item_id, store, tstore, bridge)
    elif source == "turnkey":
        item = next((i for i in turnkey_catalog(node) if i["id"] == item_id), None)
        if not item:
            raise ApiError(404, "Modèle inconnu")
        args = ("turnkey", node, item_id, item["name"], store, tstore, bridge)
    else:
        raise ApiError(400, "Source inconnue")
    job_id = secrets.token_hex(6)
    _store_jobs[job_id] = job = {"id": job_id, "source": source, "name": item["name"], "status": "running",
                                 "at": int(time.time()), "log": []}
    threading.Thread(target=run_store_job, args=(job, *args), daemon=True).start()
    return {"job": job_id}


def r_store_uninstall(d):
    vmid = str(d.get("vmid", ""))
    item = read_json(INSTALLED_FILE, {}).get(vmid) if vmid.isdigit() else None
    if not item:  # garde-fou : seules les apps installées par le Store se désinstallent d'ici
        raise ApiError(403, "Cette machine n'a pas été installée par le Store")
    vmid = int(vmid)
    if any(j.get("vmid") == vmid and j["status"] == "running" for j in list(_store_jobs.values())):
        raise ApiError(409, "Une désinstallation est déjà en cours")
    job_id = secrets.token_hex(6)
    _store_jobs[job_id] = job = {"id": job_id, "kind": "uninstall", "source": item["source"], "name": item["name"],
                                 "status": "running", "at": int(time.time()), "log": [], "vmid": vmid}
    threading.Thread(target=run_store_job, args=(job, "uninstall", vmid, bool(d.get("backup", True))), daemon=True).start()
    return {"job": job_id}


def r_store_job(q):
    j = _store_jobs.get(str(q.get("id", "")))
    if not j:
        raise ApiError(404, "Installation inconnue (PVE Hub a peut-être redémarré)")
    return j


# ---------------------------------------------------------------- rapport du matin
REPORT_PROMPT = """Tu es Hermes, l'assistant du serveur Proxmox de l'utilisateur. Rédige son rapport du matin en français,
à partir de l'état ci-dessous. Format strict :
- 1re ligne : une seule phrase de moins de 110 caractères qui résume l'essentiel (elle sert de notification ;
  « Tout va bien » si rien ne mérite son attention). Pas de titre, pas de markdown sur cette ligne.
- une ligne vide
- 3 à 8 puces courtes : d'abord ce qui mérite son attention (et quoi faire), puis le reste en bref.
N'exécute aucune commande et ne propose pas de bloc d'action : c'est un rapport à lire."""


def report_facts():
    """État du serveur en texte, et liste des points à vérifier (pour le repli sans IA)."""
    s, now, facts, issues = alert_settings(), int(time.time()), [], []
    try:
        facts.append(cluster_summary())
    except ApiError as e:
        issues.append(f"Proxmox injoignable : {e.msg}")
    try:
        b = r_maint_backups({})
        facts.append("Sauvegardes planifiées : " + ("; ".join(f"{j['schedule']} ({'toutes' if j['all'] else j['vmid']} → {j['storage']})"
                                                         for j in b["jobs"]) or "aucune"))
        if not b["jobs"]:
            issues.append("aucune sauvegarde planifiée")
        for f in b["failed"]:
            if now - f["starttime"] < 86400:
                issues.append(f"sauvegarde en échec ({f['status']})")
        for g in b["guests"]:
            age = f"il y a {(now - g['last']['ctime']) // 3600} h" if g["last"] else "jamais"
            facts.append(f"- dernière sauvegarde de {g['name'] or g['vmid']} : {age}{'' if g['planned'] else ' (non planifiée)'}")
            if g["planned"] and (not g["last"] or now - g["last"]["ctime"] > 7 * 86400):
                issues.append(f"{g['name'] or g['vmid']} pas sauvegardée depuis 7 jours")
    except ApiError:
        pass
    try:
        for _key, label, used, total in disk_items(pve("GET", "/nodes") or [], pve("GET", "/cluster/resources", {"type": "storage"}) or [],
                                                   pve("GET", "/cluster/resources", {"type": "vm"}) or []):
            if total and used / total >= 0.7:
                facts.append(f"{label} : {100 * used / total:.0f} % utilisé")
                if 100 * used / total >= s["disk_threshold"]:
                    issues.append(f"{label[0].lower() + label[1:]} plein à {100 * used / total:.0f} %")
    except ApiError:
        pass
    try:
        for d in r_disks({})["disks"]:
            p = disk_problems(d)
            facts.append(f"Disque {d['model']} ({d['dev']}) : {'; '.join(p) if p else 'OK'}"
                         + (f", {d['temp']} °C" if d.get("temp") is not None else ""))
            if p:
                issues.append(f"disque {d['model']} : {', '.join(p)}")
    except ApiError:
        pass
    cts = [c for c in _updates["cts"].values() if c["packages"]]
    if cts:
        facts.append("Mises à jour en attente : " + ", ".join(f"{c['name']} ({len(c['packages'])})" for c in cts))
    recent = [a for a in read_json(ALERTS_FILE, {}).get("state", {}).get("log", []) if now - a["ts"] < 86400]
    facts.append("Alertes des dernières 24 h : " + ("; ".join(f"{a['title']} — {a['body']}" for a in recent) or "aucune"))
    return "\n".join(facts), issues


def generate_report(push=True):
    """Rédige le rapport (Hermes, sinon version factuelle), l'enregistre et l'envoie en notification."""
    facts, issues = report_facts()
    text, by = None, "hermes"
    if hermes_on():
        try:
            r = hermes("POST", "/v1/chat/completions", {"model": "hermes-agent", "messages": [
                {"role": "system", "content": REPORT_PROMPT + "\n\nÉtat du serveur :\n" + facts},
                {"role": "user", "content": f"Rapport du matin du {local_now().strftime('%d/%m/%Y')}"}]}, timeout=300)
            text = (r["choices"][0]["message"]["content"] or "").strip() or None
        except (ApiError, KeyError, IndexError, TypeError) as e:
            print("Rapport : Hermes indisponible,", getattr(e, "msg", e), file=sys.stderr)
    if not text:  # repli sans IA : les faits bruts
        by = "local"
        head = "Tout va bien ✓" if not issues else f"{len(issues)} point{'s' if len(issues) > 1 else ''} à vérifier : " + ", ".join(issues)
        text = head[:150] + "\n\n" + facts
    summary = re.sub(r"[*_#`>]", "", next(l for l in text.splitlines() if l.strip())).strip()[:160]
    rep = {"id": secrets.token_hex(5), "ts": int(time.time()), "summary": summary, "text": text, "by": by}
    with _push_lock:
        write_json(REPORTS_FILE, ([rep] + read_json(REPORTS_FILE, []))[:14])
    if push:
        send_push("☀️ Rapport du matin", summary, "/#report", tag="report")
    log_event("report", "Rapport du matin", summary, "/#report")
    return rep


def r_reports(_):
    return {"reports": read_json(REPORTS_FILE, [])}


_report_busy = threading.Lock()


def r_report_now(_):
    """Lance la rédaction en arrière-plan ; l'app attend que le rapport apparaisse dans /api/reports."""
    if not _report_busy.acquire(blocking=False):
        raise ApiError(409, "Un rapport est déjà en cours de rédaction")

    def run():
        try:
            generate_report(push=True)
        finally:
            _report_busy.release()
    threading.Thread(target=run, daemon=True).start()
    return {"started": int(time.time())}


# ---------------------------------------------------------------- accès à distance (Tailscale)
def own_ip():
    """IP de ce conteneur vue depuis l'hôte Proxmox."""
    import socket
    host = urllib.parse.urlsplit(PVE_URL)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((host.hostname, host.port or 8006))  # UDP : aucun paquet envoyé, juste le choix de l'interface
        return s.getsockname()[0]


def serve_url_for(serve_cfg, ip, port=PORT):
    """Adresse HTTPS d'un `tailscale serve` (sur l'hôte) qui redirige vers ip:port, sinon None."""
    for hostport, web in (serve_cfg.get("Web") or {}).items():
        for handler in (web.get("Handlers") or {}).values():
            target = urllib.parse.urlsplit(handler.get("Proxy") or "")
            if target.hostname == ip and (target.port or 80) == port:
                return "https://" + (hostport[:-4] if hostport.endswith(":443") else hostport)
    return None


def r_remote(_):
    """Adresse HTTPS d'accès à distance : Tailscale de l'hôte (serve vers ce conteneur), sinon celui du conteneur."""
    info = {"ctid": read_local("CTID") or None, "repo": UPDATE_REPO}
    if EXEC_ENABLED:
        code, out = run_ssh("tailscale serve status --json 2>/dev/null", timeout=10)
        try:
            url = serve_url_for(json.loads(out), own_ip()) if code == 0 else None
        except (ValueError, OSError, AttributeError):
            url = None
        if url:
            return {**info, "installed": True, "state": "Running", "url": url, "via": "host"}
    try:
        p = subprocess.run(["tailscale", "status", "--json"], capture_output=True, timeout=5)
        st = json.loads(p.stdout or b"{}")
    except FileNotFoundError:
        return {**info, "installed": False}
    except (subprocess.TimeoutExpired, ValueError):
        return {**info, "installed": True, "state": "Unknown"}
    name = (st.get("Self") or {}).get("DNSName", "").rstrip(".")
    return {**info, "installed": True, "state": st.get("BackendState"), "url": f"https://{name}" if name else None}


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
    # vérification GitHub une fois par semaine ; « Vérifier maintenant » (check=1) la force tout de suite
    if q.get("check") or _upd["data"] is None or time.time() - _upd["at"] > 7 * 86400:
        try:
            # dernier commit exact puis VERSION à ce commit : évite le cache de 5 min de raw.githubusercontent.com
            sha = json.loads(github(f"https://api.github.com/repos/{UPDATE_REPO}/commits/main"))["sha"]
            remote = github(f"https://raw.githubusercontent.com/{UPDATE_REPO}/{sha}/VERSION").strip()
            _upd["data"] = {"remote": remote, "sha": sha, "error": None}
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            _upd["data"] = {"remote": None, "sha": None, "error": f"GitHub injoignable : {getattr(e, 'reason', e)}"}
        _upd["at"] = time.time()
    d = _upd["data"]
    return {"local": local or None, "remote": d["remote"], "error": d["error"], "checked_at": int(_upd["at"]),
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
    log_event("update", "PVE Hub mis à jour", f"Version {v['remote']}")
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
                    j = json.loads(text)
                    text = j.get("out-data", "") if isinstance(j, dict) else text
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
    """True : répond en HTTP. False : ne répond pas. None : répond, mais pas en HTTP (pas une app web)."""
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "PVEHub"})
    try:
        with UP_OPENER.open(req, timeout=3):
            return True
    except urllib.error.HTTPError:
        return True  # 401, 404… : le service répond
    except http.client.HTTPException:
        return None  # SSH, base de données, jeu… sur ce port
    except Exception:  # noqa: BLE001 — un test de statut ne doit jamais faire planter la page
        return False


def r_apps(q):
    every = all_guests()
    guests = [g for g in every if g.get("status") == "running"]
    with _installed_lock:
        inst = read_json(INSTALLED_FILE, {})
        by_id = {g["vmid"]: g for g in every}
        alive = {k: v for k, v in inst.items() if same_guest(v, by_id.get(int(k)))}
        if alive != inst:  # supprimé depuis Proxmox : on l'oublie
            write_json(INSTALLED_FILE, alive)
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
            st = alive.get(str(g["vmid"]))
            base = st["name"] if st else g.get("name") or str(g["vmid"])
            apps.append({"id": f"{g['id']}:{p}", "name": f"{base} · {PORT_NAMES.get(p) or p}", "base": base,
                         "url": url, "guest": f"{g['type']}/{g['vmid']}", "store": g["vmid"] if st else None})
    seen = {a["store"] for a in apps}
    for g in guests:  # app du Store dont aucun port n'a été détecté : on garde l'adresse affichée à l'installation
        st = alive.get(str(g["vmid"]))
        if st and st.get("url") and g["vmid"] not in seen:
            apps.append({"id": f"store:{g['vmid']}", "name": st["name"], "url": st["url"],
                         "guest": f"{g['type']}/{g['vmid']}", "store": g["vmid"]})
    for link in cfg["links"]:
        apps.append({**link, "custom": True})
    for a in apps:
        a.update({k: v for k, v in cfg["over"].get(a["id"], {}).items() if k in ("url", "hidden")})
    visible = [a for a in apps if not a.get("hidden")]
    with ThreadPoolExecutor(16) as ex:
        for a, up in zip(visible, ex.map(lambda a: is_up(a["url"]), visible)):
            a["up"] = up
    # un port détecté qui ne parle pas HTTP n'est pas une app (sauf si tu as saisi son adresse toi-même)
    apps = [a for a in apps if a.get("up") is not None or a.get("hidden") or a.get("custom") or "url" in cfg["over"].get(a["id"], {})]
    per_guest = {}
    for a in apps:
        per_guest[a.get("guest")] = per_guest.get(a.get("guest"), 0) + 1
    for a in apps:
        if a.get("up") is None and not a.get("hidden"):
            a["up"] = False
        if "base" in a and per_guest[a["guest"]] == 1:
            a["name"] = a["base"]  # une seule app sur la machine : pas besoin de préciser le port
        a.pop("base", None)
        a["name"] = cfg["over"].get(a["id"], {}).get("name") or a["name"]  # nom choisi par l'utilisateur
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
    if tf not in ("hour", "day", "week", "month"):
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


DISK_KEYS = ("rootfs", "scsi0", "virtio0", "sata0", "ide0")


def int_in(d, k, lo, hi, label):
    try:
        v = int(d[k])
    except (TypeError, ValueError):
        raise ApiError(400, f"{label} invalide")
    if not lo <= v <= hi:
        raise ApiError(400, f"{label} : entre {lo} et {hi}")
    return v


def r_guest_config(d):
    """Réglages d'une machine : démarrage avec le serveur, cœurs, mémoire (Mo), agrandissement du disque (Go)."""
    node, typ, vmid = guest_args(d)
    params = {}
    if "onboot" in d:
        params["onboot"] = 1 if d["onboot"] else 0
    if "cores" in d:
        params["cores"] = int_in(d, "cores", 1, 128, "Nombre de cœurs")
    if "memory" in d:
        params["memory"] = int_in(d, "memory", 64, 1024 * 1024, "Mémoire (Mo)")
    grow = int_in(d, "disk_grow", 0, 4096, "Agrandissement du disque (Go)") if d.get("disk_grow") else 0
    if not params and not grow:
        raise ApiError(400, "Rien à changer")
    if params:
        pve("PUT", f"/nodes/{node}/{typ}/{vmid}/config", params)
    if grow:  # Proxmox ne sait qu'agrandir : « +N G »
        cfg = pve("GET", f"/nodes/{node}/{typ}/{vmid}/config") or {}
        disk = next((k for k in DISK_KEYS if k in cfg), None)
        if not disk:
            raise ApiError(409, "Disque principal introuvable")
        wait_pve_task(node, pve("PUT", f"/nodes/{node}/{typ}/{vmid}/resize", {"disk": disk, "size": f"+{grow}G"}))
    status = (pve("GET", f"/nodes/{node}/{typ}/{vmid}/status/current") or {}).get("status")
    # une VM allumée applique cœurs et mémoire au prochain démarrage (sauf hotplug) ; un conteneur, tout de suite
    later = typ == "qemu" and status == "running" and ("cores" in params or "memory" in params)
    return {"ok": True, **params, "disk_grow": grow, "restart_needed": later}


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
    ("POST", "/api/store/uninstall"): r_store_uninstall,
    ("GET", "/api/events"): r_events,
    ("GET", "/api/disks"): r_disks,
    ("GET", "/api/store/removed"): r_store_removed,
    ("POST", "/api/store/restore"): r_store_restore,
    ("GET", "/api/schedules"): r_schedules,
    ("POST", "/api/schedules"): r_schedules_save,
    ("POST", "/api/settings"): r_app_settings,
    ("GET", "/api/chats"): r_chats,
    ("GET", "/api/chats/get"): r_chat_get,
    ("POST", "/api/chats/save"): r_chat_save,
    ("POST", "/api/chats/delete"): r_chat_delete,
    ("GET", "/api/overview"): r_overview,
    ("GET", "/api/rrd"): r_rrd,
    ("GET", "/api/guest"): r_guest,
    ("POST", "/api/power"): r_power,
    ("POST", "/api/guest/config"): r_guest_config,
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
    ("GET", "/api/chat/stream"): Handler.chat_stream,
    ("POST", "/api/chat/approval"): r_approval,
    ("POST", "/api/exec"): r_exec,
    ("GET", "/api/maint/backups"): r_maint_backups,
    ("GET", "/api/maint/updates"): r_maint_updates,
    ("POST", "/api/maint/upgrade"): r_maint_upgrade,
    ("GET", "/api/maint/job"): r_maint_job,
    ("GET", "/api/cron"): r_cron,
    ("POST", "/api/cron"): r_cron_save,
    ("GET", "/api/push"): r_push_info,
    ("POST", "/api/push/subscribe"): r_push_subscribe,
    ("POST", "/api/push/unsubscribe"): r_push_unsubscribe,
    ("POST", "/api/push/test"): r_push_test,
    ("POST", "/api/alerts"): r_alert_settings,
    ("GET", "/api/reports"): r_reports,
    ("GET", "/api/store"): r_store,
    ("GET", "/api/store/options"): r_store_options,
    ("POST", "/api/store/install"): r_store_install,
    ("GET", "/api/store/job"): r_store_job,
    ("POST", "/api/report/now"): r_report_now,
    ("GET", "/api/version"): r_version,
    ("GET", "/api/remote"): r_remote,
    ("POST", "/api/update"): r_update,
    ("GET", "/api/apps"): r_apps,
    ("POST", "/api/apps/save"): r_apps_save,
}


if __name__ == "__main__":
    if not auth_enabled():
        print("⚠️  APP_PASSWORD vide : l'interface est accessible sans mot de passe.", file=sys.stderr)
    threading.Thread(target=monitor_loop, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print(f"PVE Hub sur http://{HOST}:{PORT} → {PVE_URL}" + (f" | Hermes {HERMES_URL}" if HERMES_URL else ""))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
