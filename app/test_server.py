"""Tests rapides : python3 app/test_server.py (non inclus dans l'installeur)."""
import importlib.util
import os

os.environ.setdefault("PVE_URL", "http://x")
os.environ.setdefault("PVE_TOKEN", "t")
spec = importlib.util.spec_from_file_location("server", os.path.join(os.path.dirname(__file__), "server.py"))
srv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(srv)

# ss -Htln (Debian) : localhost, ::1 et le résolveur systemd sont ignorés
SS = """LISTEN 0 4096 0.0.0.0:8123 0.0.0.0:*
LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*
LISTEN 0 128 [::]:22 [::]:*
LISTEN 0 511 [::1]:6000 [::]:*
LISTEN 0 511 *:80 *:*
LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*"""
assert srv.parse_ports(SS) == {8123, 22, 80}, srv.parse_ports(SS)

# netstat -tln (busybox, Alpine)
NS = """Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:8080            0.0.0.0:*               LISTEN
tcp        0      0 :::9000                 :::*                    LISTEN
tcp        0      0 127.0.0.1:3000          0.0.0.0:*               LISTEN"""
assert srv.parse_ports(NS) == {8080, 9000}, srv.parse_ports(NS)

for bad in ("javascript:alert(1)", "ftp://x", "http://", "x" * 400):
    try:
        srv.clean_url(bad)
        raise AssertionError(bad)
    except srv.ApiError:
        pass
assert srv.clean_url(" http://192.168.1.1 ") == "http://192.168.1.1"
# is_up : un port qui ne parle pas HTTP ne doit jamais faire planter la page (bug « Erreur interne »)
import socket, threading
REAL_THREAD = threading.Thread
def _fake_tcp(reply):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
    def serve():
        while True:
            c, _ = s.accept(); c.recv(200); c.sendall(reply); c.close()
    threading.Thread(target=serve, daemon=True).start()
    return f"http://127.0.0.1:{s.getsockname()[1]}"
assert srv.is_up(_fake_tcp(b"SSH-2.0-pas-du-http\r\n")) is None
assert srv.is_up(_fake_tcp(b"")) is None or srv.is_up(_fake_tcp(b"")) is False
assert srv.is_up(_fake_tcp(b"HTTP/1.0 401 Unauthorized\r\n\r\n")) is True
assert srv.is_up("http://127.0.0.1:1") is False

# notifications : chiffrement identique au vecteur officiel de la RFC 8291 (annexe A)
if srv.PUSH_OK:
    from cryptography.hazmat.primitives.asymmetric import ec
    eph = ec.derive_private_key(int.from_bytes(srv.unb64u("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"), "big"), ec.SECP256R1())
    out = srv.encrypt_push(b"When I grow up, I want to be a watermelon",
                           "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
                           "BTBZMqHH6r4Tts7J_aSIgg", salt=srv.unb64u("DGv6ra1nlYgDCS1FRnbzlw"), eph=eph)
    assert srv.b64u(out) == ("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_"
                             "yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
else:
    print("(cryptography absent : test des notifications ignoré)")

# alertes : machine arrêtée sans demande, arrêts volontaires ignorés
NOW = 1_800_000_000
G = lambda vmid, st, t="lxc": {"id": f"{t}/{vmid}", "vmid": vmid, "type": t, "status": st, "name": f"m{vmid}"}
prev = {"lxc/101": "running", "lxc/102": "running", "qemu/103": "running", "lxc/104": "stopped"}
now_g = [G(101, "stopped"), G(102, "stopped"), G(103, "stopped", "qemu"), G(104, "stopped")]
tasks = [{"type": "vzshutdown", "id": "102", "starttime": NOW - 60, "endtime": NOW - 50, "status": "OK"},
         {"type": "qmstop", "id": "103", "starttime": NOW - 3600, "endtime": NOW - 3590, "status": "OK"}]  # trop ancien
al = srv.check_stopped(prev, now_g, tasks, NOW)
assert [a[2] for a in al] == ["/#g=lxc/101", "/#g=qemu/103"], al            # 102 arrêtée volontairement, 104 l'était déjà
assert srv.check_stopped(prev, now_g, tasks + [{"type": "vzdump", "id": "", "starttime": NOW - 100}], NOW) == []  # sauvegarde en cours

# alertes : disque — franchissement, pas de répétition avant 24 h, réarmement sous le seuil - 5
alerted = {}
items = [("st:pve:local", "Le stockage local", 92, 100), ("node:pve", "Le disque système de pve", 50, 100)]
assert len(srv.check_disk(items, 90, alerted, NOW)) == 1 and "st:pve:local" in alerted
assert srv.check_disk(items, 90, alerted, NOW + 3600) == []
assert len(srv.check_disk(items, 90, alerted, NOW + 90000)) == 1
srv.check_disk([("st:pve:local", "x", 80, 100)], 90, alerted, NOW + 90001)
assert "st:pve:local" not in alerted

# alertes : sauvegardes en échec depuis le dernier passage, une seule fois
t2 = [{"type": "vzdump", "id": "101", "starttime": NOW - 200, "endtime": NOW - 100, "status": "job errors"},
      {"type": "vzdump", "id": "", "starttime": NOW - 900, "endtime": NOW - 800, "status": "OK"}]
al, since = srv.check_failed_backups(t2, NOW - 1000)
assert len(al) == 1 and since == NOW - 100
assert srv.check_failed_backups(t2, since)[0] == []

rows = [{"vmid": 1, "name": "a", "planned": True, "last": {"ctime": NOW - 86400}},
        {"vmid": 2, "name": "b", "planned": True, "last": {"ctime": NOW - 9 * 86400}},
        {"vmid": 3, "name": "c", "planned": True, "last": None},
        {"vmid": 4, "name": "d", "planned": False, "last": None}]   # pas planifiée : on ne harcèle pas
al = srv.check_late_backups(rows, NOW)
assert len(al) == 1 and "b, c" in al[0][1] and "d" not in al[0][1].split(":")[1], al
assert srv.check_late_backups(rows[:1], NOW) == []

# Tailscale de l'hôte : retrouver l'adresse qui redirige vers ce conteneur
SERVE = {"TCP": {"443": {"HTTPS": True}, "8443": {"HTTPS": True}},
         "Web": {"host-005.tail1234.ts.net:443": {"Handlers": {"/": {"Proxy": "https+insecure://127.0.0.1:8006"}}},
                 "host-005.tail1234.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://192.168.1.50:8080"}}}}}
assert srv.serve_url_for(SERVE, "192.168.1.50", 8080) == "https://host-005.tail1234.ts.net:8443"
SERVE["Web"]["host-005.tail1234.ts.net:443"]["Handlers"]["/"]["Proxy"] = "http://192.168.1.50:8080"
assert srv.serve_url_for(SERVE, "192.168.1.50", 8080) == "https://host-005.tail1234.ts.net"
assert srv.serve_url_for(SERVE, "192.168.1.99", 8080) is None and srv.serve_url_for({}, "x") is None

# sauvegardes planifiées : quelle machine est couverte par quel job
assert srv.job_covers({"all": 1, "exclude": "104,105"}, 101) and not srv.job_covers({"all": 1, "exclude": "104,105"}, 104)
assert srv.job_covers({"vmid": "100,101"}, 101) and not srv.job_covers({"vmid": "100,1010"}, 101)
assert not srv.job_covers({"all": 1, "enabled": 0}, 101)

# crontab : tâches actives/désactivées, commentaires et variables conservés
CRON = """# m h  dom mon dow   command
SHELL=/bin/bash
*/5 * * * * /usr/local/bin/check.sh > /dev/null 2>&1
#0 3 * * 1-5 apt update
# Rappel : sauvegarde le dimanche
@reboot   /root/start.sh
30 2 1 jan,jul * echo semestre"""
jobs = [e for e in srv.parse_cron(CRON) if e["job"]]
assert [(e["i"], e["enabled"], e["sched"], e["cmd"]) for e in jobs] == [
    (2, True, "*/5 * * * *", "/usr/local/bin/check.sh > /dev/null 2>&1"),
    (3, False, "0 3 * * 1-5", "apt update"),
    (5, True, "@reboot", "/root/start.sh"),
    (6, True, "30 2 1 jan,jul *", "echo semestre")], jobs
for ok in ("0 3 * * *", "*/15 * * * *", "@daily", "0 0 1 1 sun"):
    assert srv.RE_CRON_SCHED.match(ok), ok
for bad in ("0 3 * *", "m h dom mon dow", "@hier", "0 3 * * * *", "0 3 * * $(id)"):
    assert not srv.RE_CRON_SCHED.match(bad), bad
# store : en-tête d'un script communautaire (variables simples ou indentées selon l'OS choisi)
HDR = '''#!/usr/bin/env bash
# Source: https://jellyfin.org/
APP="Jellyfin"
var_tags="${var_tags:-media;arr}"
var_cpu="${var_cpu:-2}"
if [[ "${var_os:-}" == "alpine" ]]; then
  var_ram="${var_ram:-256}"
  var_disk="${var_disk:-1}"
fi
'''
it = srv.parse_cs_header("jellyfin", HDR)
assert it == {"id": "jellyfin", "name": "Jellyfin", "tags": ["media", "arr"], "cpu": 2, "ram": 256, "disk": 1,
              "os": "", "site": "https://jellyfin.org/"}, it
assert srv.parse_cs_header("x", "#!/bin/bash\necho rien") is None
assert not srv.RE_SLUG.match("jellyfin; rm -rf /") and srv.RE_SLUG.match("home-assistant")

# rapport du matin : une fois par jour à l'heure choisie ; un état partiel ne fait pas planter la surveillance
import datetime, tempfile
srv.DATA_DIR = tempfile.mkdtemp()
srv.EVENTS_FILE = os.path.join(srv.DATA_DIR, "events.json")
srv.ALERTS_FILE, srv.REPORTS_FILE = os.path.join(srv.DATA_DIR, "a.json"), os.path.join(srv.DATA_DIR, "r.json")
srv.write_json(srv.ALERTS_FILE, {"state": {"log": []}})
srv.pve = lambda m, path, params=None, timeout=30: []
started = []
srv.generate_report = lambda push=True: started.append(1)
srv.threading.Thread = lambda target, daemon: type("T", (), {"start": lambda self: target()})()
srv.r_alert_settings({"report": True, "report_time": "08:00"})
for hhmm, day, expect in (("07:59", 14, 0), ("08:00", 14, 1), ("21:00", 14, 1), ("08:05", 15, 2)):
    h, m = map(int, hhmm.split(":"))
    srv.local_now = lambda s=None, h=h, m=m, day=day: datetime.datetime(2026, 10, day, h, m)
    srv.monitor_once({"prev": {}, "first": False})
    assert len(started) == expect, (hhmm, day, started)
try:
    srv.r_alert_settings({"report_time": "25:00"})
    raise AssertionError("heure invalide acceptée")
except srv.ApiError:
    pass
# sécurité : sessions révocables, mot de passe changé dans l'app, journal des connexions
srv.AUTH_FILE = os.path.join(srv.DATA_DIR, "auth.json")
srv.APP_PASSWORD = "initial-pass"
srv.send_push = lambda *a: 0
srv.threading.Thread = lambda target, daemon, args=(): type("T", (), {"start": lambda self: target(*args)})()
assert srv.check_password("initial-pass") and not srv.check_password("initial-pas")
c1 = srv.make_session("100.64.0.1", "", "iPhone")
c2 = srv.make_session("100.64.0.2", "", "Mac")
sid1, sid2 = c1.split(".")[1], c2.split(".")[1]
assert srv.session_id(c1) == sid1 and srv.session_id(c2) == sid2
assert srv.session_id(c1[:-1] + ("1" if c1[-1] == "0" else "0")) is None and srv.session_id("123.abc") is None
srv.end_sessions(only=sid2)                                                    # déconnecter un seul appareil
assert srv.session_id(c2) is None and srv.session_id(c1) == sid1
c3 = srv.make_session()
srv.end_sessions(keep=sid1)                                                    # « déconnecter les autres appareils »
assert srv.session_id(c3) is None and srv.session_id(c1) == sid1
srv.end_sessions(keep=sid1, pw=srv.hash_pw("nouveau-mot-de-passe"))
assert srv.check_password("nouveau-mot-de-passe") and not srv.check_password("initial-pass") and srv.session_id(c1) == sid1
for i in range(35):
    srv.log_login(i % 2 == 0, "100.64.0.1", "", "Mozilla/5.0 (iPhone)")
st = srv.auth_state()
assert list(st["sessions"]) == [sid1] and st["warned"], st.keys()
ev = srv.r_events({"kind": "login"})["events"]
assert len(ev) == 35 and ev[0]["ok"] is True and ev[1]["title"] == "Mot de passe incorrect", ev[:2]   # plus récent d'abord
# store : suivi des apps installées, désinstallation (sauvegarde → arrêt → suppression), fusion dans l'onglet Apps
srv.threading.Thread = REAL_THREAD
srv.INSTALLED_FILE, srv.APPS_FILE = os.path.join(srv.DATA_DIR, "inst.json"), os.path.join(srv.DATA_DIR, "apps.json")
GUESTS = [{"vmid": 101, "node": "pve", "type": "lxc", "status": "running", "name": "hermes", "id": "lxc/101"}]
calls = []
def fake_pve(m, path, params=None, timeout=30):
    calls.append((m, path.split("?")[0]))
    if path == "/cluster/resources": return GUESTS
    if path.endswith("/storage"): return [{"storage": "local"}]
    return "UPID:x"
srv.pve, srv.wait_pve_task = fake_pve, lambda n, u: "OK"
job = {"name": "2FAuth", "source": "community", "log": []}
GUESTS.append({"vmid": 120, "node": "pve", "type": "lxc", "status": "running", "name": "2fauth", "id": "lxc/120"})
srv.remember_install(job, {101})                           # pas d'ID dans le journal : le seul nouveau conteneur
assert job["vmid"] == 120 and "120" in srv.read_json(srv.INSTALLED_FILE, {})
job["url"] = "http://192.0.2.9:8000"; srv.remember_install(job, {101})
srv._scan.update(at=srv.time.time(), data={"ips": {"lxc/120": "192.0.2.9"}, "ports": {}})
srv.is_up = lambda u: True
apps = srv.r_apps({})["apps"]
assert [(a["name"], a["store"]) for a in apps] == [("2FAuth", 120)], apps   # aucun port vu : lien gardé de l'installation
srv._scan["data"]["ports"] = {"lxc/120": {8000}}
apps = srv.r_apps({})["apps"]
assert [(a["name"], a["url"], a["store"]) for a in apps] == [("2FAuth", "http://192.0.2.9:8000", 120)], apps
try:
    srv.r_store_uninstall({"vmid": 101}); raise AssertionError("machine hors Store désinstallable")
except srv.ApiError:
    pass
calls.clear(); srv.uninstall({"name": "2FAuth", "log": []}, 120, True)
srv.run_store_job({"name": "Demo", "source": "x", "log": []}, "uninstall", 999, False)   # machine absente : échec journalisé
assert srv.r_events({"kind": "store"})["events"][0]["title"] == "Demo : échec"
assert [c for c in calls if c[0] != "GET"] == [("POST", "/nodes/pve/vzdump"), ("POST", "/nodes/pve/lxc/120/status/stop"),
                                              ("DELETE", "/nodes/pve/lxc/120")], calls
assert srv.read_json(srv.INSTALLED_FILE, {}) == {}
srv.wait_pve_task = lambda n, u: "backup failed"; calls.clear()
try:
    srv.uninstall({"name": "x", "log": []}, 120, True); raise AssertionError
except srv.ApiError as e:
    assert "rien n'a été supprimé" in e.msg and not any(c[0] == "DELETE" for c in calls)
# conversations Hermes : enregistrement, liste (plus récente d'abord), suppression, validation
srv.CHATS_FILE = os.path.join(srv.DATA_DIR, "chats.json")
srv.r_chat_save({"id": "aaaa1111", "title": "  Disque   plein ?  ", "messages": [{"role": "user", "content": "x"}, {"role": "system", "content": "pirate"}]})
srv.r_chat_save({"id": "bbbb2222", "messages": [{"role": "assistant", "content": "☀️ Rapport"}], "report": "r1"})
c = srv.r_chat_get({"id": "aaaa1111"})
assert c["title"] == "Disque plein ?" and [m["role"] for m in c["messages"]] == ["user"], c        # rôle inconnu écarté
lst = srv.r_chats({})["chats"]
assert {x["id"] for x in lst} == {"aaaa1111", "bbbb2222"} and next(x for x in lst if x["id"] == "bbbb2222")["report"] == "r1"
for bad in ({"id": "../etc", "messages": []}, {"id": "aaaa1111", "messages": "x"}):
    try:
        srv.r_chat_save(bad); raise AssertionError(bad)
    except srv.ApiError:
        pass
srv.r_chat_delete({"id": "aaaa1111"})
assert [x["id"] for x in srv.r_chats({})["chats"]] == ["bbbb2222"]
# Hermes désactivable : l'onglet disparaît et les appels sont refusés
srv.APP_FILE, srv.HERMES_URL = os.path.join(srv.DATA_DIR, "app.json"), "http://h:8642"
assert srv.hermes_on()
assert srv.r_app_settings({"hermes": False})["hermes"] is False and not srv.hermes_on()
try:
    srv.hermes("GET", "/x"); raise AssertionError("Hermes appelé alors que désactivé")
except srv.ApiError as e:
    assert "désactivé" in e.msg
srv.r_app_settings({"hermes": True}); srv.HERMES_URL = ""
assert not srv.hermes_on()                                        # pas configuré : jamais actif
# même ID réutilisé par Proxmox pour une autre machine : jamais désinstallée par erreur
assert srv.same_guest({"guest": "2fauth"}, {"name": "2fauth"}) and not srv.same_guest({"guest": "2fauth"}, {"name": "nas"})
assert srv.same_guest({}, {"name": "x"}) and not srv.same_guest({"guest": "x"}, None)
# heure locale (le conteneur est en UTC)
assert srv.local_time(0, {"tz": "Europe/Paris"}).hour == 1 or not srv.local_time(0, {"tz": "Europe/Paris"}).tzinfo
# app hors ligne : seulement après 2 échecs de suite, et seulement si l'app a déjà répondu
st = {}
A = lambda up, i="lxc/101:8096", h=False: [{"id": i, "name": "Jellyfin", "url": "http://x:8096", "up": up, "hidden": h}]
assert srv.check_apps(st, A(True)) == ([], [])
assert srv.check_apps(st, A(False))[0] == []                      # un raté isolé : rien
assert len(srv.check_apps(st, A(False))[0]) == 1                  # deux ratés : alerte
assert srv.check_apps(st, A(False))[0] == []                      # pas de répétition
assert srv.check_apps(st, A(True)) == ([], ["Jellyfin"])          # revenue
st2 = {}
for _ in range(3):
    assert srv.check_apps(st2, A(False, "link:dead"))[0] == []     # jamais vue en ligne : pas d'alerte
assert srv.check_apps(st, A(False, h=True)) == ([], []) and st == {}   # masquée : oubliée
# mises à jour : conteneur (texte), VM (JSON de l'agent QEMU), VM sans agent, hôte
import json as _j
OUT = "\n".join(["@@host", "pm=apt", "bash", "@@101", "pm=apk", "musl", "busybox",
                  "@@104", _j.dumps({"exitcode": 0, "exited": 1, "out-data": "pm=apt\nopenssl\n"}), "@@105"])
f = srv.parse_updates(OUT)
assert f["host"] == {"pm": "apt", "packages": ["bash"]} and f[101] == {"pm": "apk", "packages": ["musl", "busybox"]}
assert f[104] == {"pm": "apt", "packages": ["openssl"]} and f[105] == {"pm": None, "packages": []}, f
assert srv.qm_output(_j.dumps({"pid": 42}))[0] == 124            # délai dépassé : pas un succès
assert srv.qm_output(_j.dumps({"exitcode": 3, "exited": 1, "err-data": "E"})) == (3, "E")
assert "qm guest exec 104 --timeout 60" in srv.guest_exec({"type": "qemu", "vmid": 104}, "id", 60)
# réglages d'une machine : démarrage avec le serveur, ressources, agrandissement du disque
put = []
def fake(m, path, params=None, timeout=30):
    put.append((m, path, params))
    if path.endswith("/config") and m == "GET": return {"scsi0": "local-lvm:vm-104-disk-0,size=32G"}
    if path.endswith("/status/current"): return {"status": "running"}
    return "UPID:x"
srv.pve, srv.wait_pve_task = fake, lambda n, u: "OK"
assert srv.r_guest_config({"node": "pve", "type": "lxc", "vmid": 101, "onboot": True})["onboot"] == 1
assert put[0] == ("PUT", "/nodes/pve/lxc/101/config", {"onboot": 1})
put.clear(); r = srv.r_guest_config({"node": "pve", "type": "qemu", "vmid": 104, "cores": 4, "memory": 4096, "disk_grow": 8})
assert ("PUT", "/nodes/pve/qemu/104/config", {"cores": 4, "memory": 4096}) in put
assert ("PUT", "/nodes/pve/qemu/104/resize", {"disk": "scsi0", "size": "+8G"}) in put and r["restart_needed"] is True
for bad in ({"cores": 0}, {"memory": "x"}, {"disk_grow": 99999}, {}):
    try:
        srv.r_guest_config({"node": "pve", "type": "lxc", "vmid": 101, **bad}); raise AssertionError(bad)
    except srv.ApiError:
        pass
# santé des disques : température SATA / NVMe, problèmes, alerte une fois par jour
assert srv.parse_smart_temp({"attributes": [{"id": 194, "name": "Temperature_Celsius", "raw": "38 (Min/Max 20/45)"}]}) == 38
assert srv.parse_smart_temp({"type": "text", "text": "Critical Warning: 0x00\nTemperature:                        41 Celsius\n"}) == 41
assert srv.parse_smart_temp({}) is None
D = lambda **k: {"node": "pve", "dev": "/dev/sda", "model": "WD Red", "type": "hdd", "health": "PASSED", "wearout": None, "temp": 40, **k}
assert srv.disk_problems(D()) == [] and srv.disk_problems(D(health="UNKNOWN")) == []
assert len(srv.disk_problems(D(health="FAILED", temp=58))) == 2           # HDD : 55 °C max
assert srv.disk_problems(D(type="nvme", temp=58)) == [] and srv.disk_problems(D(type="ssd", wearout=92))
al = {}
assert len(srv.check_disks([D(health="FAILED")], al, NOW)) == 1
assert srv.check_disks([D(health="FAILED")], al, NOW + 3600) == []         # pas de répétition dans la journée
assert srv.check_disks([D()], al, NOW + 7200) == [] and al == {}           # réparé : réarmé
# horaires : à l'heure dite (10 min de marge), une seule fois par jour, selon les jours choisis
import datetime as _dt
IT = [{"id": "a", "time": "23:00", "days": "week", "enabled": True}, {"id": "b", "time": "08:00", "days": "weekend", "enabled": True},
      {"id": "c", "time": "23:00", "days": "all", "enabled": False}]
done = {}
wed = lambda h, m: _dt.datetime(2026, 10, 14, h, m)        # mercredi
assert srv.due_schedules(IT, wed(22, 59), done) == []
assert [i["id"] for i in srv.due_schedules(IT, wed(23, 3), done)] == ["a"]
assert srv.due_schedules(IT, wed(23, 4), done) == []                    # déjà fait aujourd'hui
assert srv.due_schedules(IT, _dt.datetime(2026, 10, 15, 23, 15), done) == []   # plus de 10 min de retard
assert [i["id"] for i in srv.due_schedules(IT, _dt.datetime(2026, 10, 17, 8, 0), {})] == ["b"]   # samedi
srv.SCHED_FILE = os.path.join(srv.DATA_DIR, "sched.json")
r = srv.r_schedules_save({"op": "add", "node": "pve", "type": "qemu", "vmid": 104, "action": "shutdown", "time": "23:30", "days": "all"})
sid = r["items"][0]["id"]
assert srv.r_schedules_save({"op": "toggle", "id": sid})["items"][0]["enabled"] is False
for bad in ({"action": "reboot"}, {"time": "25:00"}, {"days": "lundi"}):
    try:
        srv.r_schedules_save({"op": "add", "node": "pve", "type": "lxc", "vmid": 101, "action": "start", "time": "07:00", "days": "all", **bad}); raise AssertionError(bad)
    except srv.ApiError:
        pass
assert srv.r_schedules_save({"op": "delete", "id": sid})["items"] == []
calls = []
srv.pve = lambda m, path, params=None, timeout=30: calls.append((m, path))
G2 = [{"vmid": 104, "type": "qemu", "node": "pve", "status": "stopped", "name": "jeux"}]
srv.run_schedule({"vmid": 104, "type": "qemu", "action": "start", "time": "08:00"}, G2)
srv.run_schedule({"vmid": 104, "type": "qemu", "action": "shutdown", "time": "23:00"}, G2)   # déjà éteinte : rien
assert calls == [("POST", "/nodes/pve/qemu/104/status/start")], calls
assert srv.r_events({})["events"][0]["title"] == "Allumage programmé : VM 104 « jeux »"
# horaire sur plusieurs machines : ordre respecté, machines déjà éteintes ignorées, une ligne de Journal
calls.clear()
G3 = [{"vmid": v, "type": "lxc", "node": "pve", "status": st, "name": f"c{v}"} for v, st in ((106, "running"), (107, "stopped"), (108, "running"))]
srv.run_schedule({"action": "shutdown", "time": "21:00", "targets": [{"node": "pve", "type": "lxc", "vmid": v} for v in (106, 107, 108)]}, G3)
assert calls == [("POST", "/nodes/pve/lxc/106/status/shutdown"), ("POST", "/nodes/pve/lxc/108/status/shutdown")], calls
assert srv.r_events({})["events"][0]["title"] == "Extinction programmée : 2 machines".replace("programmée", "programmé")
srv.write_json(srv.SCHED_FILE, [{"id": "old", "node": "pve", "type": "qemu", "vmid": 104, "action": "start", "time": "08:00", "days": "all", "enabled": True}])
assert srv.load_sched()[0]["targets"] == [{"node": "pve", "type": "qemu", "vmid": 104}]    # ancien format repris
r = srv.r_schedules_save({"op": "add", "action": "shutdown", "time": "21:00", "days": "all",
                          "targets": [{"node": "pve", "type": "lxc", "vmid": 106}, {"node": "pve", "type": "lxc", "vmid": 107}, {"node": "pve", "type": "lxc", "vmid": 106}]})
new = r["items"][-1]; assert len(new["targets"]) == 2                                  # doublon retiré
r = srv.r_schedules_save({"op": "update", "id": new["id"], "action": "shutdown", "time": "22:00", "days": "week", "targets": new["targets"]})
assert r["items"][-1]["time"] == "22:00" and r["items"][-1]["enabled"] is True
r = srv.r_schedules_save({"op": "remove_target", "id": new["id"], "type": "lxc", "vmid": 106}); assert len(r["items"][-1]["targets"]) == 1
r = srv.r_schedules_save({"op": "remove_target", "id": new["id"], "type": "lxc", "vmid": 107}); assert all(i["id"] != new["id"] for i in r["items"])
try:
    srv.r_schedules_save({"op": "add", "action": "start", "time": "08:00", "days": "all", "targets": []}); raise AssertionError
except srv.ApiError:
    pass
print("ok")
