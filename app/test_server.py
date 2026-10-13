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
print("ok")
