"""Bucket store: shipped map + learned state overrides.

- Shipped: lib/app-categories.json (taxonomy, freedesktop bridge, curated
  apps for the standard Omarchy set). Read-only, updates with the plugin.
- Learned: ~/.local/state/laya-workspace/app-buckets.json — entries written
  when a new app is classified (install-time or discovery pass). Survives
  plugin updates; user-editable; pruned when the app uninstalls.
"""

from __future__ import annotations

import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SHIPPED_PATH = os.path.join(HERE, "app-categories.json")

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-workspace")
LEARNED_PATH = os.path.join(STATE_DIR, "app-buckets.json")

DESKTOP_DIRS = [
    "/usr/share/applications",
    os.path.join(HOME, ".local/share/applications"),
    "/usr/share/omarchy/applications",
]

SAME_APP_AS = {
    "google-chrome": "chromium",
    "libreoffice-startcenter": "libreoffice-writer",
    "foot-server": "foot",
    "footclient": "foot",
}


def normalize(stem: str) -> str:
    return stem.lower().removesuffix(".desktop")


def installed_apps() -> dict[str, dict]:
    """normalized desktop id -> {name, cats, comment, generic}."""
    out: dict[str, dict] = {}
    for d in DESKTOP_DIRS:
        for f in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            stem = normalize(os.path.basename(f))
            if stem in out:
                continue
            meta = {"name": stem, "cats": "", "comment": "", "generic": ""}
            nodisplay = False
            try:
                with open(f, errors="replace") as fh:
                    for line in fh:
                        if line.startswith("NoDisplay=true") or line.startswith("Hidden=true"):
                            nodisplay = True
                            break
                        if line.startswith("Name="):
                            meta["name"] = line.split("=", 1)[1].strip()
                        elif line.startswith("Categories="):
                            meta["cats"] = line.split("=", 1)[1].strip()
                        elif line.startswith("Comment="):
                            meta["comment"] = line.split("=", 1)[1].strip()
                        elif line.startswith("GenericName="):
                            meta["generic"] = line.split("=", 1)[1].strip()
            except Exception:
                pass
            if not nodisplay:
                out[stem] = meta
    return out


def load_shipped() -> dict:
    with open(SHIPPED_PATH) as f:
        return json.load(f)


def load_learned() -> dict:
    """{category: [normalized ids]} plus 'descriptions': {id: text}."""
    try:
        with open(LEARNED_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_learned(learned: dict) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = LEARNED_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(learned, f, indent=1)
    os.replace(tmp, LEARNED_PATH)


def learn(learned: dict, stem: str, category: str) -> None:
    """Assign a stem to a category, removing it from all others (move semantics)."""
    learned.setdefault("apps", {})
    for cat, ids in learned["apps"].items():
        if cat != category and stem in ids:
            ids.remove(stem)
    learned["apps"].setdefault(category, [])
    if stem not in learned["apps"][category]:
        learned["apps"][category].append(stem)


def prune(learned: dict, installed: dict) -> int:
    """Drop learned entries whose app is no longer installed. Returns pruned."""
    pruned = 0
    for cat in list(learned.get("apps", {}).keys()):
        kept = []
        for stem in learned["apps"][cat]:
            if stem in installed:
                kept.append(stem)
            else:
                pruned += 1
        learned["apps"][cat] = kept
    desc = learned.get("descriptions", {})
    for stem in list(desc.keys()):
        if stem not in installed:
            del desc[stem]
            pruned += 1
    return pruned


def resolve(stem: str, shipped: dict, learned: dict) -> str | None:
    """Category for a stem: learned overrides shipped; None = unbucketed."""
    if stem in learned.get("apps", {}):
        for cat, ids in learned["apps"].items():
            if stem in ids:
                return cat
    return bridge_or_none(stem, shipped)


def bridge_or_none(stem: str, shipped: dict) -> str | None:
    """Deterministic tier-1: desktop Categories= tokens via the bridge."""
    meta = installed_apps().get(stem)
    if not meta:
        return None
    bridge = shipped.get("bridge", {})
    for token in meta["cats"].split(";"):
        token = token.strip()
        if token in bridge:
            return bridge[token]
    return None


def bucket_for(stem: str, shipped: dict, learned: dict) -> str:
    """Always returns a category; unknown stems default to utilities."""
    cat = resolve(stem, shipped, learned)
    if cat:
        return cat
    # Learned descriptions and the bridge both missed: check the shipped
    # curated lists too (covers hand-seeded entries), else utilities.
    for cat, ids in shipped.get("apps", {}).items():
        if stem in ids:
            return cat
    return "utilities"
