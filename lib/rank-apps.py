import json
import sys

sys.path.insert(0, '/home/cheapseatsecon/Projects/omarchy-plugins/omarchy-laya-workspace/lib')
import buckets as bk
import classify as cls

FRAMING = ' Multiple applications are typically open side by side in such a '
QTAIL = ' typically be open side by side in a workspace used for '

shipped = bk.load_shipped()
learned = bk.load_learned()
installed = bk.installed_apps()

import sys as _sys
if len(_sys.argv) < 2:
    print('usage: ranktest.py PURPOSE CATEGORY', file=_sys.stderr)
    sys.exit(2)
purpose = _sys.argv[1]
category = _sys.argv[2]
max_apps = int(_sys.argv[3]) if len(_sys.argv) > 3 else 3

cands = []
for stem, meta in sorted(installed.items()):
    if stem in bk.SAME_APP_AS:
        continue
    if bk.bucket_for(stem, shipped, learned) == category:
        cands.append((stem, meta['name']))

questions = {}
for stem, display in cands:
    questions['app::' + stem] = {'type': 'noul', 'instructions': 'Would ' + display + QTAIL + purpose + '?'}
r = cls.laya(purpose + '.' + FRAMING, questions)
scored = []
for key, ans in r['answers'].items():
    stem = key.split('::', 1)[1]
    scored.append((float(ans['noul']), stem))
scored.sort(key=lambda t: -t[0])
real_ids = []
for score, stem in scored[:max_apps]:
    match = next((x for x in installed if bk.normalize(x) == stem), stem)
    real_ids.append(match + ".desktop")
print(json.dumps({"apps": real_ids, "scores": {s: round(sc, 4) for sc, s in scored[:max_apps]}}))
