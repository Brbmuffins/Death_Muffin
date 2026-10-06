# godot/next/hero: the hero body and what it wears

`dm_hero_body.gd` (`DmHeroBody`): the session body (DmAvatar model, vitals, navmesh mover, collider, enemy target contract). The avatar's
lantern is the **local** hero's only (a remote puppet carries none: one light per peer, as the current client).

`dm_hero_look.gd` (`DmHeroLook`, child `Look` of DmNextGame, same path on every peer): worn gear, cape, pet and hero ring.
- **Gear**: `DmAvatar.set_equipment` (weapon in hand, off-hand, helm / hide-helm, body tints by material tier, legendary set aura) from the
  equipped bag rows. `set_equipment` diffs per slot; `DmHeroLook` also skips an unchanged gear set, so an unrelated bag change rebuilds nothing.
- **Cape / pet**: `DmAvatar.set_cape`, `DmPetView` (trails the owner, idles, snaps when far; parented to the game). Source = the Capes & Pets panel:
  `_cosmetics_act` -> backend -> `DmNextUiHost.refresh_character` -> `load_cosmetics` -> `Look.set_cosmetics`.
- **Hero ring** (local hero only): contact shadow + pale ring, discipline glow + bone ring, cursor reticle, soul halo, hover ring (`DmGame._dress_hero`).
- **Settings -> Hide helm** reaches the avatars (`DmAvatar.refresh_all` in `DmNextUiHost._apply_settings_side_effects`).

## Replication
A look = `{"g": {slot: [item_id, rarity]}, "c": cape_id, "p": pet_id}` (~320 B as a `var` with a full legendary set). The owner builds it (host with
panels: bag signal + panel; otherwise `Look.load_from_api()` from the character's own backend), applies it locally and, only when it changed, sends it
reliably: the host to everyone (`_rpc_look`), a joiner to the host (`_rpc_submit`), which stores it and relays it. The host replays every known look to
a joiner 0.8 s after it joins. A body whose avatar is not built yet is dressed in `_make_avatar` (`Look.dress`). Descriptors from peers are shape-checked
(`_valid`: known slots, string ids) and only ever name catalogue items, so a forged look can only show a catalogue piece.

## Cost (headless, shared VPS; `tests/next_hero_look/run.gd`)
Frame median with full gear + cape + pet: ~7.3 ms, identical with the pet frozen (pet update ~0.003 ms). Equip change: ~0.2 ms to unequip, ~0.7 ms to
re-equip sword + chest. A remote pet farther than 35 m from the local hero animates at 8 Hz.

## Gaps
No friendly rim (nothing in the current client sets one on the hero). The hover ring follows hover only (the current client also follows the
attack target / auto target). Remote heroes get no ring or halo (as the current client's remotes). Online joiners without panels use their backend's
bag and cosmetics at join time and do not live-update (they have no Reliquary yet).
