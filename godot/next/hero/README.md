# godot/next/hero: the hero body and what it wears

`dm_hero_body.gd` (`DmHeroBody`): the session body (DmAvatar model, vitals, navmesh mover, collider, enemy target contract). The avatar's
lantern is the **local** hero's only (a remote puppet carries none: one light per peer).

`dm_hero_look.gd` (`DmHeroLook`, child `Look` of DmNextGame, same path on every peer): worn gear, cape, pet and hero ring.
- **Gear**: `DmAvatar.set_equipment` (weapon in hand, off-hand, helm / hide-helm, light body tints by rarity, set look) from the
  equipped bag rows. `set_equipment` diffs per slot (a weapon also by rarity); `DmHeroLook` also skips an unchanged gear set, so an unrelated bag change rebuilds nothing.
  Weapons and the default staff are held in the palm and follow the hand (`DmCreature.attach_held`, grips per kind in `DmGearProps.HOLDS`), so a cast clip that
  throws the weapon hand throws the staff; bolts with a staff play the flick, big rites the slam, summons the summon, channels the channel (`castClips.json`).
  Rarity and element glow on the weapon tip, the set aura (2 / 4 pieces) and the set's colour scheme (3+): `game/dm_gear_fx.gd`, see `godot/game/README.md` "Held props and gear look".
- **Models**: weapons, the tier helm, the class / ascended set mantle and, at 3+ pieces of a legendary set, the set's hero body are real models (`game/dm_gear_models.gd`, `data/slice/necro_gear.json`, `godot/game/README.md` "Held props and gear look"). All of it derives from the gear in the look descriptor, so a remote peer builds the same look; the legendary body swap is part of `DmAvatar.set_equipment`.
- The Reaper's weapon slot always shows her green-etched scythe (`DmAvatar._reaper`, `DmGearProps.scythe_model`), whatever weapon her bag row names, and she gestures with it as a scythe.
- **Cape / pet**: `DmAvatar.set_cape`, `DmPetView` (trails the owner, idles, snaps when far; parented to the game). Source = the Capes & Pets panel:
  `_cosmetics_act` -> backend -> `DmNextUiHost.refresh_character` -> `load_cosmetics` -> `Look.set_cosmetics`.
- **Hero ring** (local hero only): contact shadow + pale ring, discipline glow + bone ring, cursor reticle, soul halo, hover ring.
- **Settings -> Hide helm** reaches the avatars (`DmAvatar.refresh_all` in `DmNextUiHost._apply_settings_side_effects`).

## Replication
A look = `{"g": {slot: [item_id, rarity]}, "c": cape_id, "p": pet_id, "e": element}` (~320 B as a `var` with a full legendary set; `e` is optional: the weapon element the owner's socketed
runes give, one of `DmGearFx.ELEMENTS`, absent when none). The owner builds it (host with
panels: bag signal + panel; otherwise `Look.load_from_api()` from the character's own backend), applies it locally and, only when it changed, sends it
reliably: the host to everyone (`_rpc_look`), a joiner to the host (`_rpc_submit`), which stores it and relays it. The host replays every known look to
a joiner 0.8 s after it joins. A body whose avatar is not built yet is dressed in `_make_avatar` (`Look.dress`). Descriptors from peers are shape-checked
(`_valid`: known slots, string ids) and only ever name catalogue items, so a forged look can only show a catalogue piece.

## Cost (headless, shared VPS)
Frame median with full gear + cape + pet: ~7.3 ms, identical with the pet frozen (pet update ~0.003 ms). Equip change: ~0.3 ms to unequip, ~1 ms to
re-equip sword + chest (a first-time model load adds ~9 ms for weapon + off-hand + helm + mantle). A legendary body swap: ~3.6 ms with the model prefetched (2 pieces), ~85-100 ms cold (model load + mesh bake). Gear is 1 draw call per model: weapon, off-hand, helm, mantle. Full legendary dressing (weapon halo + 16 motes, set aura 14 motes, tints): avatar update 0.042 ms vs 0.035 ms bare (headless; CPUParticles3D, never GPU-simulated: DECISIONS B12; object count flat over 240 frames). A remote pet farther than 35 m from the local hero animates at 8 Hz.

## Tests / known gaps
Suites: `tests/next_hero_look/run.gd` (the node, replication), `tests/gear_look/run.gd` (grips, clips, tint, rarity / element / set effects, the real gear models and the legendary swap).
No friendly rim on the hero. The hover ring follows hover only (not the attack or auto target). Remote heroes get no ring or halo. Online joiners without panels use their backend's
bag and cosmetics at join time and do not live-update (they have no Reliquary yet).
