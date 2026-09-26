/**
 * Status matrix beyond Fracture / Withered / Miasma slow (FUTURE_CONTENT 0.4).
 * Colour language: Hemorrhage = marrow (ember + dried crimson), Chill = the
 * Mourner's cold blue, Sanctified = pale enemy-priest gold.
 */
export const HEMORRHAGE = {
  /** Bleed per second as a share of the Marrow Spear hit that caused it. */
  dpsFrac: 0.12,
  /** Hard cap the host enforces on a claimed bleed (share of the hit). */
  maxFrac: 0.25,
  durationS: 4,
};

export const CHILL = {
  /** Mourner wraith hits chill: slower feet and slower attacks. */
  durationS: 2.5,
  moveMult: 0.7,
  attackRateMult: 0.75,
};

export const SANCTIFIED = {
  /** Crypt Deacons bless the nearest wounded ally when no corpse is in reach. */
  range: 6,
  durationS: 5,
  damageTakenMult: 0.7,
  /** Deacon cooldown after a blessing, as a share of its normal cooldown. */
  cooldownMult: 0.6,
};

export const BONE_HEX = {
  /** Bone-mage thrall bolts: the hexed enemy's blows land softer. */
  durationS: 3,
  damageMult: 0.75,
};

/** Plague-bearer thralls burst into a friendly rot pool when they fall (or are sacrificed). */
export const PLAGUE_BURST = {
  radius: 2.6,
  /** Burst damage as a multiple of the thrall's hit. */
  damageMult: 2.5,
  poolRadius: 2.4,
  poolMs: 5000,
  /** Pool withering dps as a share of the thrall's hit. */
  poolDpsShare: 0.35,
};

export const STATUS_FX = {
  hemorrhage: { crimson: 0x8a2c3c, ember: 0xff6a2a },
  chill: { frost: 0x9fc4ff, deep: 0x5b7fd6 },
  sanctified: { gold: 0xf2d98a, pale: 0xfff3cf },
  hex: { bone: 0xe0d6c2, amber: 0xd9a66b },
};
