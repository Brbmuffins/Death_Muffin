#!/usr/bin/env python3
"""One-off, deterministic trim of the Godot golden fixtures so the answer keys can live in git.

Usage: tools/godot/trim-fixtures.py FULL_DIR [OUT_ROOT]
  FULL_DIR  directory holding the FULL fixture sets as <suite>/<file>.json (as produced by the frozen TS generators,
            tools/godot/gen-fixtures.sh, copied per suite)
  OUT_ROOT  default godot/tests; writes OUT_ROOT/<suite>/fixtures/...

Rules
  * bosses: every scenario is kept byte-for-byte, but stored gzip'd (<name>.json.gz). The brains are stateful across ticks so ticks
    cannot be sampled; gzip gives ~8x. The suites read them through PackedByteArray.decompress_dynamic.
  * every other file <= SMALL bytes is copied unchanged.
  * larger files hold a list of independent cases (top level list, or {"cases": [...]}); they are sampled down to ~TARGET bytes:
      1. coverage pass: greedily pick the cases that add the most new "features" (value of every low-cardinality string/bool/null leaf
         at each normalised key path, plus min/max case for each numeric path), up to COVER_CAP x quota;
      2. fill the rest of the quota with an even stride over the original order (so numeric ranges / seeds stay spread out).
    Original order is preserved in the output. Files that are not a list of cases are copied unchanged.
Prints cases before -> after per file as a table.
"""
import gzip, json, os, sys, math

SMALL = 200_000
TARGET = 150_000
MIN_CASES = 20
COVER_CAP = 1.3
LOWCARD = 40
SUITES = ["bosses", "dialogue", "gear", "rules-combat", "rules-gathering", "rules-loot", "rules-progression", "ui_parity"]


def leaves(x, path, out):
    if isinstance(x, dict):
        for k, v in x.items():
            leaves(v, path + "." + str(k), out)
    elif isinstance(x, list):
        for v in x:
            leaves(v, path + "[]", out)
    else:
        out.append((path, x))


def features(case):
    out = []
    leaves(case, "", out)
    return out


def sample(cases, quota_bytes_per_case_total):
    n = len(cases)
    quota = max(MIN_CASES, min(n, int(n * TARGET / quota_bytes_per_case_total)))
    if quota >= n:
        return list(range(n))
    feats = [features(c) for c in cases]
    domain = {}
    for fl in feats:
        for p, v in fl:
            if isinstance(v, (str, bool)) or v is None:
                domain.setdefault(p, set()).add(v if not isinstance(v, str) else v)
    lowcard = {p for p, s in domain.items() if len(s) <= LOWCARD}
    cfeat = []
    nums = {}
    for i, fl in enumerate(feats):
        s = set()
        for p, v in fl:
            if p in lowcard and (isinstance(v, (str, bool)) or v is None):
                s.add((p, v))
            elif isinstance(v, (int, float)) and not isinstance(v, bool):
                nums.setdefault(p, []).append((v, i))
        cfeat.append(s)
    for p, lst in nums.items():
        lo = min(lst, key=lambda t: (t[0], t[1]))
        hi = max(lst, key=lambda t: (t[0], -t[1]))
        cfeat[lo[1]].add((p, "min"))
        cfeat[hi[1]].add((p, "max"))
    chosen = {0, n - 1}
    covered = set(cfeat[0]) | set(cfeat[n - 1])
    cap = max(quota, int(quota * COVER_CAP))
    while len(chosen) < cap:
        best, bi = 0, -1
        for i in range(n):
            if i in chosen:
                continue
            g = len(cfeat[i] - covered)
            if g > best:
                best, bi = g, i
        if bi < 0:
            break
        chosen.add(bi)
        covered |= cfeat[bi]
    need = quota - len(chosen)
    if need > 0:
        step = n / need
        for j in range(need):
            i = int(j * step + step / 2)
            while i in chosen and i < n - 1:
                i += 1
            chosen.add(i)
    return sorted(chosen)


def main():
    full = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else "godot/tests"
    rows = []
    for suite in SUITES:
        sdir = os.path.join(full, suite)
        odir = os.path.join(root, suite, "fixtures")
        os.makedirs(odir, exist_ok=True)
        for fn in sorted(os.listdir(sdir)):
            if not fn.endswith(".json"):
                continue
            raw = open(os.path.join(sdir, fn), "rb").read()
            if suite == "bosses":
                with open(os.path.join(odir, fn + ".gz"), "wb") as f:
                    f.write(gzip.compress(raw, 9, mtime=0))
                rows.append((suite, fn, "scenario", "scenario", len(raw), len(gzip.compress(raw, 9, mtime=0))))
                continue
            data = json.loads(raw)
            holder = None
            if isinstance(data, list):
                cases = data
            elif isinstance(data, dict) and isinstance(data.get("cases"), list) and set(data.keys()) <= {"fn", "cases"}:
                cases, holder = data["cases"], data
            else:
                cases = None
            out = raw
            before = after = "-"
            if len(raw) > SMALL and cases is not None:
                idx = sample(cases, len(raw))
                kept = [cases[i] for i in idx]
                before, after = len(cases), len(kept)
                if holder is not None:
                    holder["cases"] = kept
                    out = json.dumps(holder, separators=(",", ":")).encode()
                else:
                    out = json.dumps(kept, separators=(",", ":")).encode()
            elif cases is not None:
                before = after = len(cases)
            with open(os.path.join(odir, fn), "wb") as f:
                f.write(out)
            rows.append((suite, fn, before, after, len(raw), len(out)))
    for r in rows:
        print("%-18s %-28s %6s -> %-6s %9d -> %9d" % r)
    tot = sum(r[5] for r in rows)
    print("TOTAL bytes written: %d (%.1f MB)" % (tot, tot / 1e6))


if __name__ == "__main__":
    main()
