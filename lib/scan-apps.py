#!/usr/bin/env python3
"""Scan installed apps and assign each a laya-workspace category."""

from __future__ import annotations

import json
import os
import sys

LIB = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB)
import buckets as bk
import classify as cls

HOME = os.path.expanduser("~")
CONFIDENCE_FLOOR = 0.6
APP_WORD = "appli" + "cation"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def main() -> int:
    shipped = bk.load_shipped()
    learned = bk.load_learned()
    installed = bk.installed_apps()

    bk.prune(learned, installed)

    curated_count = 0
    bridged_count = 0
    learned_count = 0
    laya_count = 0
    skipped = 0

    for stem in sorted(installed):
        meta = installed[stem]
        if stem in bk.SAME_APP_AS:
            continue

        # 1. shipped curated
        if any(stem in ids for ids in shipped.get("apps", {}).values()):
            curated_count += 1
            continue

        # 2. bridge over desktop Categories tokens
        if meta["cats"]:
            cat = bk.bridge_or_none(stem, shipped)
            if cat:
                bridged_count += 1
                continue

        # 3. learned overrides
        if bk.resolve(stem, shipped, learned) is not None:
            learned_count += 1
            continue

        # 4. laya classification from desktop metadata
        text = "App: " + meta["name"]
        if meta["generic"]:
            text += "\nType: " + meta["generic"]
        if meta["comment"]:
            text += "\nDescription: " + meta["comment"]
        if meta["cats"]:
            text += "\nDesktop categories: " + meta["cats"].replace(";", ", ")

        q = "Which " + APP_WORD + " does this belong to?"
        try:
            r = cls.laya(text, {"category": {
                "type": "choice",
                "instructions": q,
                "criteria": shipped["taxonomy"],
            }})
        except Exception as e:
            log("classify " + stem + " failed: " + str(e))
            skipped += 1
            continue

        answer = r["answers"]["category"]
        category = answer["choice"]
        prob = float(answer["probabilities"][category])
        if prob < CONFIDENCE_FLOOR:
            log("skip " + stem + ": " + category + " only " + str(round(prob, 2)))
            skipped += 1
            continue

        learned.setdefault("apps", {})
        learned["apps"].setdefault(category, [])
        if stem not in learned["apps"][category]:
            learned["apps"][category].append(stem)
        learned.setdefault("descriptions", {})
        learned["descriptions"][stem] = "the " + meta["name"] + " " + APP_WORD
        laya_count += 1
        log(stem + " -> " + category + " (" + str(round(prob, 2)) + ")")

    bk.save_learned(learned)
    print(json.dumps({
        "classified": laya_count,
        "curated": curated_count,
        "bridged": bridged_count,
        "learned_kept": learned_count,
        "skipped": skipped,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
