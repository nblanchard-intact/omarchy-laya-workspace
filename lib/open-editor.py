#!/usr/bin/env python3
"""Open the learned app-bucket map in the default editor.

Creates the file first if it does not exist, so the editor has something to
edit. Uses EDITOR, falling back to common GUI editors, then xdg-open.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-workspace")
LEARNED = os.path.join(STATE_DIR, "app-buckets.json")

SEED = {
    "apps": {},
    "descriptions": {},
    "_note": "Learned app buckets. Format: {category: [desktop-id, ...]}. Entries here override the shipped map in app-categories.json. Delete an entry and rescan to reclassify.",
}


def main() -> int:
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(LEARNED):
        with open(LEARNED, "w") as f:
            json.dump(SEED, f, indent=2)

    editor = os.environ.get("EDITOR", "")
    if editor:
        subprocess.run([editor, LEARNED])
        return 0

    for candidate in ["code", "gedit", "kate", "mousepad"]:
        path = shutil.which(candidate)
        if path:
            subprocess.run([path, LEARNED])
            return 0

    subprocess.run(["xdg-open", LEARNED])
    return 0


if __name__ == "__main__":
    sys.exit(main())
