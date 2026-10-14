#!/usr/bin/env python3
"""Assemble pvehub-install.sh (un seul fichier) à partir de app/, et écrit VERSION."""
import base64, hashlib, os
D = os.path.dirname(os.path.abspath(__file__))
FILES = {"SERVER": "app/server.py", "INDEX": "app/static/index.html",
         "MANIFEST": "app/static/manifest.webmanifest", "ICON": "app/static/icon.svg", "ICONPNG": "app/static/icon.png", "ICONLIGHT": "app/static/icon-light.png", "SW": "app/static/sw.js"}
read = lambda p: open(os.path.join(D, p), "rb").read()
tpl = read("install.tpl.sh").decode()
# Version = empreinte du contenu : elle ne change que si le code change
version = hashlib.sha256(b"".join(read(p) for p in FILES.values()) + tpl.encode()).hexdigest()[:10]
s = tpl.replace("@@VERSION@@", version)
for k, p in FILES.items():
    s = s.replace(f"@@{k}@@", base64.encodebytes(read(p)).decode().rstrip())
assert "@@" not in s
open(os.path.join(D, "pvehub-install.sh"), "w").write(s)
os.chmod(os.path.join(D, "pvehub-install.sh"), 0o755)
open(os.path.join(D, "VERSION"), "w").write(version + "\n")
print("version", version)
