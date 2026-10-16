class_name DmStableSort
extends RefCounted
## JS Array.prototype.sort is stable; Godot's sort_custom is not. This is a stable merge sort over a copy.
## `less` = Callable(a, b) -> bool (strict "a goes before b").


static func sorted(arr: Array, less: Callable) -> Array:
	if arr.size() < 2:
		return arr.duplicate()
	var mid := arr.size() / 2
	var left := sorted(arr.slice(0, mid), less)
	var right := sorted(arr.slice(mid), less)
	var out: Array = []
	var i := 0
	var j := 0
	while i < left.size() and j < right.size():
		# take from the right only when strictly less: equal elements keep their original order
		if less.call(right[j], left[i]):
			out.append(right[j])
			j += 1
		else:
			out.append(left[i])
			i += 1
	while i < left.size():
		out.append(left[i])
		i += 1
	while j < right.size():
		out.append(right[j])
		j += 1
	return out
