#!/usr/bin/env python3
"""Assemble pvehub-install.sh (un seul fichier) à partir de app/."""
import base64, os
D = os.path.dirname(os.path.abspath(__file__))
b64 = lambda p: base64.encodebytes(open(os.path.join(D, "app", p), "rb").read()).decode().rstrip()
s = open(os.path.join(D, "install.tpl.sh")).read()
for k, p in {"SERVER": "server.py", "INDEX": "static/index.html",
             "MANIFEST": "static/manifest.webmanifest", "ICON": "static/icon.svg"}.items():
    s = s.replace(f"@@{k}@@", b64(p))
assert "@@" not in s
open(os.path.join(D, "pvehub-install.sh"), "w").write(s)
os.chmod(os.path.join(D, "pvehub-install.sh"), 0o755)
