// Join inventory.json + spawn.json + props.json into the "top by on-screen cost" table (markdown). node rank.mjs inv.json spawn.json props.json [propDrawnFraction=0.27]
import fs from 'fs';
const [inv, spawn, props, frac = '0.27'] = process.argv.slice(2);
const I = Object.fromEntries(JSON.parse(fs.readFileSync(inv)).map((x) => [x.file, x]));
const S = JSON.parse(fs.readFileSync(spawn)); const P = JSON.parse(fs.readFileSync(props));
const SLUG = { robber: 'grave_robber', hound: 'bone_hound', penitent: 'penitent', sac: 'carrion_sac', deacon: 'deacon', risen: 'skeleton_thrall', censer: 'censer_bearer', wraith: 'choir_wraith', rat: 'skull_rat', golem: 'bone_golem', gargoyle: 'belfry_gargoyle', moth: 'shroud_moth', bat: 'tithe_bat', seraph: 'weeping_seraph', ghoul: 'barrow_ghoul', acolyte: 'lich_acolyte', templar: 'bell_templar', plague_doctor: 'plague_doctor', flagellant: 'flagellant', cinder_husk: 'cinder_husk', pyre_priest: 'pyre_priest', cinderhound: 'cinderhound', slag_brute: 'slag_brute', bog_hag: 'bog_hag', mire_leech: 'mire_leech', fen_wisp: 'fen_wisp', drowned_sexton: 'drowned_sexton' };
const rows = [];
for (const [id, n] of Object.entries(S.avg)) { const slug = SLUG[id]; const m = I[`${slug}/character.glb`] || I[`props/${slug}.glb`]; if (!m) continue; rows.push({ name: slug, kind: 'enemy', tris: m.tris, prims: m.prims, bones: m.bones, mb: m.bytes / 1e6, count: n, cost: m.tris * n }); }
const thr = I['thrall_legionnaire/character.glb']; rows.push({ name: 'thrall_* (legion, 5 typical)', kind: 'thrall', tris: thr.tris, prims: thr.prims, bones: thr.bones, mb: thr.bytes / 1e6, count: 5, cost: thr.tris * 5 });
const hero = I['hero_gravecaller/character.glb']; rows.push({ name: 'hero_* (player)', kind: 'player', tris: hero.tris, prims: hero.prims, bones: hero.bones, mb: hero.bytes / 1e6, count: 1, cost: hero.tris });
const rob = I['grave_robber/character.glb']; rows.push({ name: 'corpses (full skinned clones, ~10 typical, cap 45)', kind: 'corpse', tris: rob.tris, prims: 1, bones: rob.bones, mb: 0, count: 10, cost: rob.tris * 10 });
for (const p of P.props) { const m = I[`props/${p.id}.glb`]; if (!m) continue; const per = Object.values(p.areas); rows.push({ name: `props/${p.id}`, kind: 'prop', tris: m.tris, prims: m.prims, bones: 0, mb: m.bytes / 1e6, count: p.total, cost: m.tris * p.total * +frac, note: `${p.total} in world, max ${Math.max(...per)}/area` }); }
rows.sort((a, b) => b.cost - a.cost);
console.log('| # | Model | Kind | Tris | Prims | Bones | File MB | Typical count | Est. tris on screen (main pass) |\n|---|---|---|---|---|---|---|---|---|');
rows.slice(0, 20).forEach((r, i) => console.log(`| ${i + 1} | ${r.name} | ${r.kind} | ${r.tris} | ${r.prims} | ${r.bones || '-'} | ${r.mb ? r.mb.toFixed(2) : '-'} | ${typeof r.count === 'number' ? (Number.isInteger(r.count) ? r.count : r.count.toFixed(1)) : r.count}${r.note ? ' (' + r.note + ')' : ''} | ${Math.round(r.cost).toLocaleString()} |`));
