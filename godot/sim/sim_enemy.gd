class_name DmSimEnemy
extends RefCounted
## One hostile body (port of `Enemy` in src/gameplay/sim/types.ts). Field names are the TS names (camelCase) on purpose: the
## bosses track and the fixtures read them 1:1. Optional TS fields default to their "undefined" value (0 / false / "" / null).
## null-able ids: targetThrall and channelCorpse use -1 for none.

var id: int = 0
var def: String = ""
var area: String = ""
var level: float = 1.0
var elite: bool = false
var x: float = 0.0
var z: float = 0.0
var facing: float = 0.0
var hp: float = 0.0
var maxHp: float = 0.0
var damage: float = 0.0
var speed: float = 0.0
var radius: float = 0.5
var scale: float = 1.0
## 'rising' | 'move' | 'windup' | 'recover' | 'channel' | 'dead' | 'burrow'
var state: String = "move"
var stateT: float = 0.0
var attackCd: float = 0.0
var targetPlayer: String = ""
var targetThrall: int = -1
var aimX: float = 0.0
var aimZ: float = 0.0
var channelCorpse: int = -1
var flankSide: float = 1.0
var fracture: float = 0.0
var fractureT: float = 0.0
var withered: float = 0.0
var witheredT: float = 0.0
var witheredDps: float = 0.0
var witheredOwner: String = ""
var contagious: bool = false
var slowT: float = 0.0
var wardSlowT: float = 0.0
var lastHitBy: String = ""
var flash: float = 0.0
var gait: float = 0.0
var moving: bool = false
var bleedT: float = 0.0
var bleedDps: float = 0.0
var bleedOwner: String = ""
var chillT: float = 0.0
var sanctT: float = 0.0
var hexT: float = 0.0
var silenceT: float = 0.0
var stunT: float = 0.0
var rootT: float = 0.0
var incenseT: float = 0.0
var knellBeats: float = 0.0
var knellNext: float = 0.0
var knellOwner: String = ""
var knellDamage: float = 0.0
var hexOwner: String = ""
var diving: bool = false
var diveX: float = 0.0
var diveZ: float = 0.0
var groundT: float = 0.0
var hooking: bool = false
var hookCd: float = 0.0
var fleeT: float = 0.0
## Barrow Ghoul: the key of the target it winds an eruption on (a player id String or a thrall id int), or null.
var erupting: Variant = null
var dugIn: bool = false
var digPending: bool = false
## null (undefined) until the ghoul first digs in; then metres of tunnel left.
var burrowLeft: Variant = null
var unbindCd: float = 0.0
## id of the Lich Acolyte that unbound this Risen, or -1.
var unboundBy: int = -1
var blockFxAt: float = 0.0
var auraCd: float = 0.0
## Elite affix id ("bellTolled" | "hungering" | "shrouded" | "vengeful") or "" for none.
var affix: String = ""
var affixCd: Variant = null
## Bell-Tolled ring waiting to sound: {t, x, z} or null.
var tollAt: Variant = null
var markT: float = 0.0
var markBonus: float = 0.0
var markBy: String = ""
var plagueAt: float = 0.0
## Catacomb Depths extra affixes: Array of {affix, affixCd (Variant), tollAt (Variant)} (Dictionaries, mutated in place).
var extra: Array = []
