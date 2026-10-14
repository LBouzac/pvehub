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
print("ok")
