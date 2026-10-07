"""Keyword tiebreaker: map purpose text to a category via app-keywords.json.

The laya category head dilutes at 10 options and scores near-uniform on
abstract purposes, so strong text evidence (code, photo, chat...) outranks
the model. Returns (category, probability) or (None, 0) when no keyword
matches strongly enough.
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
KW_PATH = os.path.join(HERE, "app-keywords.json")
BASE_CONFIDENCE = 0.6
PER_HIT = 0.1


def match(purpose_lower: str) -> tuple:
    keywords = json.load(open(KW_PATH))
    best_cat = None
    best_hits = 0
    for cat_k, kws in keywords.items():
        hits = 0
        for kw in kws:
            if kw in purpose_lower:
                hits += 1
        if hits > best_hits:
            best_cat = cat_k
            best_hits = hits
    if best_cat is None or best_hits == 0:
        return None, 0.0
    return best_cat, min(1.0, BASE_CONFIDENCE + PER_HIT * best_hits)


if __name__ == "__main__":
    import sys
    cat, prob = match(sys.argv[1].lower() if len(sys.argv) > 1 else "")
    print(cat, prob)
