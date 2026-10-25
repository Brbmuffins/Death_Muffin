# client/next/hero: the hero body and what it wears

`dm_hero_body.gd` (`DmHeroBody`): the session body (DmAvatar model, vitals, navmesh mover, enemy target contract). The hero is an external entity of the combat core (`core_id`, registered by the game scene): the core
sees him as a circle it pushes bodies out of, so he has no collider, and the blows enemies land on him arrive as the core's `EV_TARGET_HIT` events with the enemy's id as the source (`take_damage`); a chill, root or drag
arrives as `EV_TARGET_EFFECT` (`dm_enemy_effect`). The thralls he owns are counted by the core. The avatar's lantern is the **local** hero's only (a remote puppet carries none: one light per peer).
The host derives `family` (hotbar kit, HUD resource, auto combat) from the bound character; every other peer's puppets derive it from the
replicated `discipline_id` (`DmHeroBody.family_of`), so a joining Reaper plays the Reaper kit on its own client. A puppet's health is the host's vitals at 20 Hz: a fall in them is its `hurt` (client/next/hud/CORE-INTEGRATION.md).

`dm_hero_look.gd` (`DmHeroLook`, child `Look` of DmNextGame, same path on every peer): worn gear, cape, pet and hero ring.
- **Gear**: `DmAvatar.set_equipment` (weapon in hand, off-hand, helm / hide-helm, light body tints by rarity, set look) from the
  equipped bag rows. `set_equipment` diffs per slot (a weapon also by rarity); `DmHeroLook` also skips an unchanged gear set, so an unrelated bag change rebuilds nothing.
  Weapons and the default staff are held in the palm and follow the hand (`DmCreature.attach_held`, grips per kind in `DmGearProps.HOLDS`), so a cast clip that
  throws the weapon hand throws the staff; bolts with a staff play the flick, big rites the slam, summons the summon, channels the channel (`castClips.json`).
  With a staff, the discipline heroes play those clips (and idle, walk, run and cast) in their staff versions, the arm re-baked around it (client/game/README.md "Held props and gear look").
  Rarity and element glow on the weapon tip, the set aura (2 / 4 pieces) and the set's colour scheme (3+): `client/game/dm_gear_fx.gd`, see client/game/README.md "Held props and gear look".
- **Models**: weapons, the tier helm, the class / ascended set mantle and, at 3+ pieces of a legendary set, the set's hero body are real models (`client/game/dm_gear_models.gd`, `client/data/slice/necro_gear.json`, client/game/README.md "Held props and gear look"). All of it derives from the gear in the look descriptor, so a remote peer builds the same look; the legendary body swap is part of `DmAvatar.set_equipment`.
- The Reaper's weapon slot always shows her green-etched scythe (`DmAvatar._reaper`, `DmGearProps.scythe_model`), whatever weapon her bag row names, and she gestures with it as a scythe.
- **Cape / pet**: `DmAvatar.set_cape`, `DmPetView` (trails the owner, idles, snaps when far; parented to the game). Source = the Capes & Pets panel:
  `_cosmetics_act` -> backend -> `DmNextUiHost.refresh_character` -> `load_cosmetics` -> `Look.set_cosmetics`.
- **Hero ring** (local hero only): contact shadow + pale ring, discipline glow + bone ring, cursor reticle, soul halo, hover ring. The hover ring finds the hovered enemy in the core by id and follows the body the crowd draws; the ring
  decals are drawn at `RING_K` of their opacity and the contact shadow at `SHADOW_A`, because Forward+ blends a decal in linear light and the old renderer in the encoded scene (client/next/look/README.md).
- **Settings -> Hide helm** reaches the avatars (`DmAvatar.refresh_all` in `DmNextUiHost._apply_settings_side_effects`).

## Replication
A look = `{"g": {slot: [item_id, rarity]}, "c": cape_id, "p": pet_id, "e": element, "k": kit}` (~320 B as a `var` with a full legendary set; `e` is optional: the weapon element the owner's socketed
runes give, one of `DmGearFx.ELEMENTS`, absent when none; `k` is optional too: the Legion kit, `{"weapon": [item_id, rarity], "armor": [...]}` for the slots (120 and 121) that hold a piece, which `DmCoreHost.set_hero_kit` gives the crowd so the hero's thralls wear it, "client/crowd/README.md"). The owner builds it (the panels' bag signal and the Capes & Pets panel; without panels `Look.load_from_api()` reads the character's own backend), applies it locally and, only when it changed, sends it
reliably: the host to everyone (`_rpc_look`), a joiner to the host (`_rpc_submit`), which stores it and relays it. The host replays every known look to
a joiner 0.8 s after it joins. A body whose avatar is not built yet is dressed in `_make_avatar` (`Look.dress`). Descriptors from peers are shape-checked
(`_valid`: known slots, string ids) and only ever name catalogue items, so a forged look can only show a catalogue piece.

## Cost
Gear is 1 draw call per model (weapon, off-hand, helm, mantle); a remote pet farther than 35 m from the local hero animates at 8 Hz; a legendary body swap is a few ms with the model prefetched and the warm-up keeps the local discipline's body resident
(client/game/README.md).

## Tests / known gaps
`client/tests/rites.gd` builds each discipline and the Reaper as a real character in a fresh game (her set look: Soul Harbinger's Raiment, hood, body and scythe).
No friendly rim on the hero. The hover ring follows hover only (not the attack or auto target). Remote heroes get no ring or halo.
