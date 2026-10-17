class_name DmLaunchArgs
extends RefCounted
## The testing options after `--` that the boot (`--dev-offline`, `--benchmark`) and the dev entry (dev/dm_dev_entry.gd) both read. It lives with the boot:
## the export leaves dev/ out, so the boot must not name a class from there (2026-10-16: every rebuild test build until then stopped on a grey screen).
## --class=N (default 2), --level=N (1-60, default 10), --seed=N, --no-waves, --boss, --crowd=N, --baked=<dir>, --shot=<png>, --shot-after=<s> (default 25), --shot-wall=<s>,
## --bench-dir=<dir> (the benchmark keeps its files there and sends nothing).


static func options(args: PackedStringArray) -> Dictionary:
	var o := {"class": 2, "level": 10, "no_waves": false, "shot_after": 25.0}
	for a in args:
		if a.begins_with("--class="):
			o["class"] = int(a.substr(8))
		elif a.begins_with("--level="):
			o["level"] = clampi(int(a.substr(8)), 1, 60)
		elif a.begins_with("--seed="):
			o["seed"] = int(a.substr(7))
		elif a == "--no-waves":
			o["no_waves"] = true
		elif a == "--boss":
			o["boss"] = true
		elif a.begins_with("--crowd="):
			o["crowd"] = int(a.substr(8))
		elif a.begins_with("--baked="):
			o["baked"] = a.substr(8)
		elif a.begins_with("--bench-dir="):
			o["bench_dir"] = a.substr(12)
		elif a.begins_with("--shot="):
			o["shot"] = a.substr(7)
		elif a.begins_with("--shot-after="):
			o["shot_after"] = float(a.substr(13))
		elif a.begins_with("--shot-wall="):
			o["shot_wall"] = float(a.substr(12))
	return o
