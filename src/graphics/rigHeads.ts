/**
 * What the hero's own head is, per rig, so worn helms can match it (owner, 3 Oct 2026: "the most visually functional
 * version" until the character is rebuilt to match each item). Read by `NecromancerAvatar.mountHelm`:
 *  - 'covered': the model already has a hood, cowl, built-in helmet or headdress. No dome is drawn; the equipped helm
 *    shows as tint and glow on that head region instead (see Creature.setHeadTint), so the head reads clean.
 *  - 'bare': no head covering and the dome is wanted. The helm dome is drawn, sized to the head from Creature.headFit().
 * Judged by eye from the head close-ups in docs/screenshots/gear-fit (head radius cannot tell a tight hood from a
 * bald head), one entry per rig rather than per item. A rig missing here counts as 'bare'.
 */
export type HeadKind = 'covered' | 'bare';

export const RIG_HEAD: Record<string, HeadKind> = {
  hero_ossuary: 'covered', // hood
  hero_gravecaller: 'covered', // hood
  hero_mourner: 'covered', // veil hood
  hero_rotweaver: 'covered', // fungus-crowned hood
  hero_hollow_knight: 'covered', // built-in great helm
  hero_grave_warden: 'covered', // built-in helmet and cowl
  hero_veilwalker: 'covered', // wrapped cowl
  hero_carrion_witch: 'covered', // skull headdress
  hero_bell_monk: 'covered', // bald: tint only, at a lower strength so the skin reads as lit, not painted (owner, 4 Oct 2026)
};

/** Tint strength where the default (0.55) is too heavy: a bare head shows the helm as a faint trim of its colour. */
export const RIG_HEAD_STRENGTH: Record<string, number> = { hero_bell_monk: 0.25 };
