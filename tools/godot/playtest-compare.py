#!/usr/bin/env python3
"""Compare the rebuild's playtest (out/nd<N>_h) with the current game's (out/d<N>_h), per discipline.
usage: tools/godot/playtest-compare.py [--tag-suffix _h] [discs...]   (default discs 1 2 3 4)"""
import json, os, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "godot", "tests", "playtest", "out")
suffix = "_h"
args = [a for a in sys.argv[1:]]
if args and args[0] == "--tag-suffix":
    suffix = args[1]; args = args[2:]
discs = [int(a) for a in args] or [1, 2, 3, 4]
names = {1: "ossuary", 2: "gravecaller", 3: "mourner", 4: "rotweaver"}
KEYS = ["fight_kills_75s", "fight_gold_gain", "fight_xp_gain", "fight_level_after", "fight_deaths", "fight_min_hp_frac", "fight_flasks_used", "enemies_seen", "dps_single_ttk_s", "dps_pack6_ttk_s", "fight_loot_items", "fight_shards",
        "loot_drops_seen", "loot_items_picked", "loot_gold_gained", "boss_defeated", "boss_time_s", "boss_deaths", "max_enemies", "max_thralls", "relaunch_fight_kills_20s"]
def load(tag):
    out = {"metrics": {}, "frame": {}, "findings": []}
    for s in "AB":
        f = os.path.join(root, tag, s + ".json")
        if os.path.exists(f):
            r = json.load(open(f))
            # session B (the relaunch) only adds its own relaunch_* keys: its max_enemies / max_thralls would overwrite session A's
            out["metrics"].update({k: v for k, v in r.get("metrics", {}).items() if s == "A" or k.startswith("relaunch")})
            if s == "A": out["frame"] = r.get("frame", {})
            out["findings"] += [(s, x["sev"], x["title"]) for x in r["findings"]]
    return out
for d in discs:
    nx, cu = load("nd%d%s" % (d, suffix)), load("d%d%s" % (d, suffix))
    print("\n### %d %s" % (d, names[d]))
    print("| metric | rebuild | current |\n|---|---|---|")
    for k in KEYS:
        print("| %s | %s | %s |" % (k, nx["metrics"].get(k, "-"), cu["metrics"].get(k, "-")))
    for k in ["p50_ms", "p95_ms", "worst_ms", "play_over100ms"]:
        print("| frame %s | %s | %s |" % (k, nx["frame"].get(k, "-"), cu["frame"].get(k, "-")))
    for tag, r in (("rebuild", nx), ("current", cu)):
        print("findings %s: %s" % (tag, "; ".join("%s/%s %s" % f for f in r["findings"]) or "none"))
