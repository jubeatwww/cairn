#!/usr/bin/env python3
"""Read or set one value in site.secret.yaml, keeping the others. Used by the setup scripts.

    scripts/secret.py get <key>    print it (nothing if unset). Keys are dotted: gandi.pat
    scripts/secret.py set <key>    the value comes from stdin, so it never shows up in `ps`

The file is created if missing and stays readable only by you (mode 600).
"""
import os
import pathlib
import sys

import yaml

FILE = pathlib.Path(__file__).resolve().parent.parent / "site.secret.yaml"
HEADER = "# Gitignored. Never commit. Template: site.secret.example.yaml. Written by scripts/secret.py\n"


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("get", "set"):
        sys.exit(__doc__)
    cmd, keys = sys.argv[1], sys.argv[2].split(".")
    data = (yaml.safe_load(FILE.read_text()) or {}) if FILE.exists() else {}

    if cmd == "get":
        value = data
        for k in keys:
            value = value.get(k) if isinstance(value, dict) else None
        if value is not None:
            print(value)
        return

    node = data
    for k in keys[:-1]:
        node = node.setdefault(k, {})
    node[keys[-1]] = sys.stdin.read().strip()
    fd = os.open(FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(HEADER + yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
    os.chmod(FILE, 0o600)


if __name__ == "__main__":
    main()
