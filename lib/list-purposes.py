#!/usr/bin/env python3
"""Return the list of remembered purposes from purposes.json as JSON."""
from __future__ import annotations

import json
import os

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-workspace")
PURPOSES = os.path.join(STATE_DIR, "purposes.json")

try:
    with open(PURPOSES) as f:
        store = json.load(f)
except Exception:
    store = {}

rows = sorted(store.values(), key=lambda d: d.get("last_used", 0), reverse=True)
print(json.dumps(rows))
