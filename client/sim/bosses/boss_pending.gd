class_name DmBossPending
extends RefCounted
## A telegraphed attack waiting for its due time (BossBrain.ts `Pending`). Reference identity matters, hence a class.

var kind: String = ""
var at: float = 0.0
var x: float = 0.0
var z: float = 0.0
var r: float = 0.0
## Array of [x, z] pairs, or null.
var targets: Variant = null
## Facing (radians) for cones, lines and spokes, or null.
var dir: Variant = null
## A niche's attacks don't count as the boss being busy.
var side: bool = false
