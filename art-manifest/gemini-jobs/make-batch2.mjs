// Generates batch2.json (Gemini jobs for batch 2). Kept in the repo so the
// prompts that produced shipped art are reproducible: node art-manifest/gemini-jobs/make-batch2.mjs
import { writeFileSync } from 'node:fs';

const WORLD = 'necromancer-world-farming-gameplay-reference.png';
const jobs = [];

const tex = (id, desc) =>
  jobs.push({
    id: `tex_${id}`,
    out: `public/art/textures/${id}.webp`,
    refs: [WORLD],
    aspect: '1:1',
    size: '1K',
    post: { resize: [1024, 1024], format: 'webp' },
    prompt:
      'Seamless tileable game texture, perfectly tiling on all four edges, orthographic top-down (or straight-on for walls), ' +
      'flat even diffuse lighting with no directional shadows, no vignette, no text, no border, fills the entire frame edge to edge. ' +
      'Use the attached screenshot ONLY for mood and palette (layered near-blacks, soot, cold violet reflections, old bone). Subject: ' +
      desc,
  });
tex('grave_soil', 'dark graveyard ground: near-black brown damp soil, patches of dead dark grass, scattered small pebbles, a few tiny bone fragments. Dark overall value.');
tex('flagstone', 'wet gothic cathedral floor: large irregular charcoal limestone flagstones with dark grout lines, worn chipped edges, faint silver salt bloom, a few shallow puddles reflecting cold violet light. Dark overall value.');
tex('ossuary_floor', 'ossuary crypt floor of packed dark earth and old stone with bone fragments, knuckle bones and a few small skulls pressed into it. Dark overall value.');
tex('stone_wall', 'gothic crypt wall of fitted charcoal limestone blocks, soot stains, thin dead moss in the joints, straight-on front view. Dark overall value.');
tex('skull_wall', 'ossuary wall made of tightly stacked human skulls and long bones set in rows between dark stone, aged ivory and soot, straight-on front view, dense repeating pattern.');
jobs.push({
  id: 'tex_stained_glass',
  out: 'public/art/textures/stained_glass.webp',
  refs: [WORLD],
  aspect: '9:16',
  size: '1K',
  post: { format: 'webp' },
  prompt:
    'A single tall gothic lancet stained-glass window, straight-on front view, filling the frame, black background outside the arch. ' +
    'Deep violet, indigo and pale lilac glass with black lead lines, central motif of a hooded figure holding a bell above a skull, glowing as if lit from behind. No text.',
});

const ICON =
  'Dark fantasy ARPG ability icon, square, painterly and highly readable at small size, strong central silhouette, deep near-black background ' +
  'with a subtle carved-stone vignette, violet spell light (#9b5cff to #c6a4ff) and old ivory bone as the only bright accents, no text, no border frame, ' +
  'no letters. Match the style of the ability icons in the attached screenshot HUD. Subject: ';
const icon = (id, desc) =>
  jobs.push({ id: `icon_${id}`, out: `public/art/abilities/necro-${id}.png`, refs: [WORLD], aspect: '1:1', post: { resize: [256, 256], format: 'png' }, prompt: ICON + desc });
icon('needle', 'a single sharp sliver of bone flying diagonally with a violet energy trail');
icon('spear', 'a straight line of jagged bone spikes erupting from cracked ground toward the viewer');
icon('exhume', 'a skeletal hand clawing up out of a grave mound, violet light pouring from the soil');
icon('miasma', 'a swirling circle of violet and sickly green rot mist on the ground with drifting spores');
icon('litany', 'three skulls orbiting a glowing ritual sigil circle, violet burst of energy');

const ITEM =
  'Dark fantasy ARPG inventory item icon, square, single object centered, painterly and readable at small size, near-black background with a faint violet vignette, no text, no border. Subject: ';
const item = (id, desc, dir = 'items') =>
  jobs.push({ id: `item_${id}`, out: `public/art/${dir}/${id}.png`, aspect: '1:1', post: { resize: [192, 192], format: 'png' }, prompt: ITEM + desc });
item('ore_copper', 'a rough chunk of green-veined copper ore');
item('ore_tin', 'a dull pale grey chunk of tin ore');
item('ore_iron', 'a rust-streaked chunk of dark iron ore');
item('ore_silver', 'a chunk of tarnished silver ore with bright specks');
item('ore_gold', 'a chunk of dark rock with veins of gold');
item('ingot_copper', 'a single copper ingot bar');
item('ingot_iron', 'a single dark iron ingot bar');
item('ingot_gold', 'a single gold ingot bar stamped with a skull');
item('flask_hp_minor', 'a small corked glass potion vial of dark red healing draught');
item('flask_hp_major', 'a larger ornate corked flask of glowing crimson healing draught with a bone stopper');
item('helm_copper', 'a dented copper helmet');
item('helm_iron', 'a blackened iron helm with a narrow visor');
item('helm_gold', 'a gold-tempered ceremonial helm shaped like a broken mitre');
item('plate_copper', 'a copper breastplate');
item('chest_iron', 'a salt-bloomed blackened iron chestplate');
item('sword_copper', 'a short copper sword');
item('staff_oak', 'a gnarled coffin-oak staff topped with a small skull');
item('augment_copper', 'a small copper reliquary charm with a violet gem');
item('augment_iron', 'an iron reliquary charm with a bone inlay and a violet gem');
item('log_oak', 'a short length of dark oak log');
item('kit_iron_warden', 'a bundle of iron plates and oak planks bound with leather straps');
item('gold', 'a small pile of old gold coins', 'ui');
item('soul_shard', 'a jagged glowing violet soul crystal shard', 'ui');
item('fracture', 'a cracked bone glowing with violet fracture light, status effect icon', 'status');

const PORTRAIT =
  'Dark fantasy character portrait, waist-up, painterly, dramatic low-key lighting, near-black background with violet haze, no text. ' +
  'Base the character on the attached hooded necromancer (same hood, face and robes). Variant: ';
const por = (id, desc) =>
  jobs.push({
    id: `portrait_${id}`,
    out: `public/art/portraits/${id}.webp`,
    refs: ['art-src/concepts/necromancer.png'],
    aspect: '3:4',
    post: { resize: [480, 640], format: 'webp' },
    prompt: PORTRAIT + desc,
  });
por('ossuary', 'the Ossuary discipline: pale bone plates grown over the shoulders and forearms like armour, a skull-faced bone shield, old ivory highlights');
por('gravecaller', 'the Gravecaller discipline: a phalanx of skeletal warriors with glowing violet eyes looming behind, one hand raised commanding them, strong violet light');
por('mourner', 'the Mourner discipline: translucent silver-blue wraith spirits coiling around, a small funeral bell in hand, cold spirit light');
por('rotweaver', 'the Rotweaver discipline: surrounded by violet and sickly green miasma, rot blossoms and spores drifting from the hands');

jobs.push({
  id: 'backdrop_login',
  out: 'public/art/login-backdrop.webp',
  refs: [WORLD],
  aspect: '16:9',
  size: '2K',
  post: { resize: [1920, 1080], format: 'webp' },
  prompt:
    'Wide cinematic dark fantasy vista for a game login screen: a moonlit graveyard in the foreground with leaning tombstones and an iron fence, ' +
    'a ruined gothic cathedral with a violet-lit stained glass window in the distance, violet mist, corpse candles, no characters, no text, no UI. ' +
    'Keep the centre of the image darker and calmer (negative space for a login panel). Palette: layered near-blacks, plum, cold silver moonlight, violet spell light, old bone.',
});

const PROP =
  '3D modeling reference image of a single isolated game prop, three-quarter view from slightly above, the whole object visible and centered, ' +
  'plain flat light grey background (#c8c8c8), even neutral studio lighting, no cast shadows, no ground plane, no text, no other objects. ' +
  'Dark fantasy style matching the attached screenshot (soot-dark stone, blackened iron, aged bone, violet accents). Subject: ';
const prop = (id, desc) =>
  jobs.push({ id: `concept_prop_${id}`, out: `art-src/concepts/props/${id}.png`, refs: [WORLD], aspect: '1:1', prompt: PROP + desc });
prop('tombstone_round', 'a weathered rounded-top headstone, cracked, moss in the crevices, a simple carved skull emblem');
prop('tombstone_cross', 'a leaning stone celtic cross grave marker on a small plinth, chipped');
prop('mausoleum', 'a small gothic family mausoleum crypt with a pointed roof, stone buttresses and a closed rusted iron door, violet light leaking from the door gap');
prop('pillar', 'a tall gothic cathedral stone column with a carved capital and a square base, soot-darkened');
prop('arch', 'a broken gothic stone archway, pointed arch with one side partly crumbled');
prop('sarcophagus', 'a stone sarcophagus with a carved effigy of a robed knight on the lid, lid slightly ajar');
prop('statue', 'a hooded mourning angel statue with folded wings on a square stone plinth, face hidden, weathered');
prop('candles', 'a cluster of many melted white and ivory candles of different heights on a small stone base, dripping wax, not lit');
prop('bone_pile', 'a heap of human skulls and long bones');
prop('fence', 'a straight section of wrought iron cemetery fence with spear-tipped bars between two stone posts, about twice as wide as tall');
prop('dead_tree', 'a gnarled leafless dead tree with twisting branches and exposed roots');
prop('brazier', 'a blackened iron tripod brazier with a wide bowl full of dim embers');
prop('bell_altar', 'a huge cracked bronze church bell resting on a low stone altar with chains, violet light glowing from inside the crack');
prop('reliquary', 'an ornate reliquary chest of dark wood bound in blackened iron with bone ornaments and a small skull on the lid');
prop('workbench', 'a heavy ossuary workbench of dark wood with bones, skulls, tools and a small anvil on it');
prop('waystone', 'a tall standing runestone obelisk carved with glowing violet runes, on a small stone base');

writeFileSync(new URL('./batch2.json', import.meta.url), JSON.stringify(jobs, null, 2) + '\n');
console.log(`batch2.json: ${jobs.length} jobs`);
