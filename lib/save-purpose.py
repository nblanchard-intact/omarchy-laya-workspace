#!/usr/bin/env python3
"""Append/merge a classified purpose into purposes.json.

Usage: save-purpose.py '<classified-json>'

purposes.json maps purpose text -> the classification result, plus a
"workspace" name and last-used timestamp. The Service calls this after every
successful launch so the same purpose can be replayed without laya.
"""

from __future__ import annotations

import json
import os
import sys
import time

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-workspace")
PURPOSES = os.path.join(STATE_DIR, "purposes.json")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: save-purpose.py '<json>'", file=sys.stderr)
        return 2
    try:
        d = json.loads(sys.argv[1])
    except json.JSONDecodeError as e:
        print(f"bad json: {e}", file=sys.stderr)
        return 2

    purpose = str(d.get("purpose", "")).strip()
    if not purpose:
        print("no purpose", file=sys.stderr)
        return 2

    os.makedirs(STATE_DIR, exist_ok=True)
    store = {}
    if os.path.exists(PURPOSES):
        try:
            with open(PURPOSES) as f:
                store = json.load(f)
        except Exception:
            store = {}

    d["last_used"] = time.time()
    if "workspace" not in d:
        d["workspace"] = purpose
    store[purpose] = d

    tmp = PURPOSES + ".tmp"
    with open(tmp, "w") as f:
        json.dump(store, f, indent=1)
    os.replace(tmp, PURPOSES)
    return 0


if __name__ == "__main__":
    sys.exit(main())
