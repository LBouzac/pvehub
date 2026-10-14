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
print("ok")
