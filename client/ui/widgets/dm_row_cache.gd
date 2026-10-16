class_name DmRowCache
extends RefCounted
## Keeps the nodes of a list's rows between redraws. A list panel used to free and rebuild every row whenever anything changed (a looted item
## rebuilt the whole 44-recipe Workbench: ~110 ms). With this a row is rebuilt only when its own inputs changed (its `sig`), everything
## else keeps its nodes and just moves into the right place.
##   sync(container, keys, sigs, build) -> Array of the rows' payloads in `keys` order
##     build(i) -> Dictionary {"node": Control (already a child of `container`, or not yet), ...anything the owner wants back}
## Rows whose key is no longer listed are freed. Keys must be unique per list.

var _rows: Dictionary = {}   # key -> {"sig": int, "pay": Dictionary}
var built := 0               ## rows built by the last sync (the rest were reused): tests and perf logs read it
var reused := 0


func sync(container: Node, keys: Array, sigs: Array, build: Callable) -> Array:
	built = 0
	reused = 0
	var out: Array = []
	var want := {}
	for i in keys.size():
		var k := String(keys[i])
		var e: Variant = _rows.get(k)
		if e != null and int(e["sig"]) == int(sigs[i]) and is_instance_valid(e["pay"]["node"]):
			reused += 1
		else:
			if e != null and is_instance_valid(e["pay"]["node"]):
				_drop(e["pay"]["node"])
			var pay: Dictionary = build.call(i)
			e = {"sig": int(sigs[i]), "pay": pay}
			_rows[k] = e
			built += 1
		want[(e["pay"]["node"] as Node).get_instance_id()] = true
		out.append(e["pay"])
	for k in _rows.keys():
		if not keys.has(k):
			var n: Node = _rows[k]["pay"]["node"]
			if is_instance_valid(n):
				_drop(n)
			_rows.erase(k)
	# Anything else in the container goes (a hint, a stale row); then the rows in order.
	for c in container.get_children():
		if not want.has(c.get_instance_id()):
			container.remove_child(c)
			c.queue_free()
	for i in out.size():
		var n: Node = out[i]["node"]
		if n.get_parent() != container:
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			container.add_child(n)
		if container.get_child(i) != n:
			container.move_child(n, i)
	return out


## Forget every row (and free their nodes).
func clear(container: Node = null) -> void:
	for k in _rows:
		var n: Node = _rows[k]["pay"]["node"]
		if is_instance_valid(n):
			_drop(n)
	_rows.clear()
	if container != null:
		for c in container.get_children():
			container.remove_child(c)
			c.queue_free()


func size() -> int:
	return _rows.size()


static func _drop(n: Node) -> void:
	if n.get_parent() != null:
		n.get_parent().remove_child(n)
	n.queue_free()
