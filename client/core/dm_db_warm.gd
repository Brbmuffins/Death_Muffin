class_name DmDbWarm
extends RefCounted
## Every dataset loaded once, on the main thread, during loading (DmNextGame.start). `DmDb` fills its cache on first use, and a Godot Dictionary is not safe to read on one thread
## while another thread inserts into it. The workers (the Depths' floor generator, the Gear Atlas' verdicts: client/README.md "Threads") read content, so the cache must stop
## changing before the first one starts: after `all()` no dataset is a first use any more. A pass over a warm cache is about a hundred lookups, so code that starts a worker
## simply calls it again (it also refills a cache that `DmDb.reset()` emptied).

static var done := false   ## a pass has run (tests)
static var datasets := 0   ## files the last pass covered (tests)


static func all() -> void:
	datasets = 0
	for rel in DmDb.all_files():
		DmDb.raw(rel)
		datasets += 1
	DmDb.combat("progression")   # the projections built from the datasets, once
	DmDb.loot_view()
	DmDb.progression_view()
	done = true
