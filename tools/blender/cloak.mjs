/**
 * cloak.mjs - a hero's cloak stops rising with the arms and the bent back (Blender job kind `cloak`, docs/BLENDER-PIPELINE.md "Jobs").
 *
 * Tripo weights loose cloth to the nearest bones, so it moves as if it were part of them. Two cases look broken in the game:
 *   - arms: the side panels hanging below the T-pose arms ride the arm bones, so an arm raised overhead (the slam) lifts them into a flat sail.
 *     Each arm gets a cloak copy of its bones (L_/R_CloakUpperarm, its twists, CloakForearm, its twists, CloakHand: the arm's rest pose and
 *     bind, under the same clavicle), and the cloth hanging below the arm moves onto it; the sleeve and the hand keep the arm. In every clip the
 *     copy follows the arm, except that its upper arm and forearm point at most `top` degrees above the chest's level (eased from level), so a
 *     pose with the arms down (idle, walk, run) is exactly the arm's.
 *   - cape: a long cape trailing behind the body rides the spine, so a deep bow (the slam's landing) stands it up behind the hero like a board.
 *     A chain Cape01..Cape04 hangs from Spine02 down the middle of the back cloth to the hem, the cloth well behind the body moves onto it by
 *     height, and in every clip each link is carried by the chest but swung down to at most `lift` degrees above its rest hang (easing over
 *     `give` more). Only for a cape that hangs free: on a robe the "back cloth" is the skirt, and it would flare.
 *
 * The rest pose and the bind are unchanged, so a still model looks the same. The settings ride in the file (L_CloakUpperarm's and Cape01's
 * extras), so a later step that changes clips re-keys the cloak the same way: jobs.mjs runs `rebakeCloak` on the clips a step touched. Pure
 * functions on a glTF-Transform Document (no Blender), unit tested in tools/blender/jobs.test.mjs.
 */
import { Matrix4, Quaternion, Vector3 } from 'three';

export const SIDES = ['L', 'R'];
const PREFIX = 'Cloak';
/** A cloak copy's name, e.g. L_Forearm -> L_CloakForearm (the shader's bone regions, dm_creature_mat.gd, still match it). */
export const cloakOf = (name) => name.replace(/^([LR])_/, `$1_${PREFIX}`);
export const isCloakBone = (name) => /^([LR]_Cloak|Cape\d)/.test(name);
export const CAPE = ['Cape01', 'Cape02', 'Cape03', 'Cape04'];   // three links down the back and the hem's end
/** keep/free: how far (share of the height) below the arm, behind the body, cloth starts to move onto the cloak and moves wholly. */
export const ARM_DEFAULTS = { level: 0, top: 20, keep: 0.03, free: 0.09 };
export const CAPE_DEFAULTS = { keep: 0.08, free: 0.14, lift: 10, give: 25 };
const UP = new Vector3(0, 1, 0);
const NEAR_UP = 0.3;   // a link this close to vertical (horizontal part, of 1) takes its azimuth from the chest instead

const smooth = (x) => { const t = Math.min(1, Math.max(0, x)); return t * t * (3 - 2 * t); };

/** The arm subtree of one side in the skin, parents first: Upperarm, its twists, Forearm, its twists, Hand (whatever the skin holds). */
function armOf(skin, side) {
  const joints = skin.listJoints();
  const inSkin = new Set(joints);
  const ua = joints.find((j) => j.getName() === `${side}_Upperarm`);
  if (!ua) return null;
  const out = [];
  const walk = (n) => { out.push(n); for (const c of n.listChildren()) if (inSkin.has(c) && !isCloakBone(c.getName())) walk(c); };
  walk(ua);
  const fa = out.find((n) => n.getName() === `${side}_Forearm`), hand = out.find((n) => n.getName() === `${side}_Hand`);
  if (!fa || !hand) throw new Error(`${side} arm: no ${side}_Forearm or ${side}_Hand under ${side}_Upperarm`);
  return { nodes: out, ua, fa, hand, clavicle: ua.getParentNode(), chest: ua.getParentNode()?.getParentNode() };
}

function skinOf(doc) {
  const skins = doc.getRoot().listSkins();
  if (skins.length !== 1) throw new Error(`the cloak job needs one skin (the model has ${skins.length})`);
  return skins[0];
}

export function hasCloak(doc) {
  return doc.getRoot().listSkins().some((s) => s.listJoints().some((j) => isCloakBone(j.getName())));
}

const nodeNamed = (doc, name) => doc.getRoot().listNodes().find((x) => x.getName() === name);
/** The settings a model's arm cloak and cape were made with (the defaults where the file has none). */
export const armLimits = (doc) => ({ ...ARM_DEFAULTS, ...(nodeNamed(doc, 'L_CloakUpperarm')?.getExtras()?.cloak ?? {}) });
export const capeLimits = (doc) => ({ ...CAPE_DEFAULTS, ...(nodeNamed(doc, CAPE[0])?.getExtras()?.cape ?? {}) });

/** Add the cloak bones (once): copies of each arm's subtree with the same rest transforms and binds. Returns the names added. */
export function addCloakBones(doc) {
  const skin = skinOf(doc);
  const joints = skin.listJoints();
  const ibm = skin.getInverseBindMatrices();
  if (!ibm) throw new Error('the skin has no inverse bind matrices');
  const have = new Set(joints.map((j) => j.getName()));
  const added = [];
  const mats = Array.from(ibm.getArray());
  for (const side of SIDES) {
    const arm = armOf(skin, side);
    if (!arm) throw new Error(`no ${side}_Upperarm: the cloak job needs the shared biped skeleton`);
    if (have.has(cloakOf(arm.ua.getName()))) continue;
    const copy = new Map();
    for (const n of arm.nodes) {
      const c = doc.createNode(cloakOf(n.getName())).setTranslation(n.getTranslation()).setRotation(n.getRotation()).setScale(n.getScale());
      (copy.get(n.getParentNode()) ?? n.getParentNode()).addChild(c);
      copy.set(n, c);
      skin.addJoint(c);
      const k = joints.indexOf(n);
      mats.push(...ibm.getArray().slice(k * 16, k * 16 + 16));
      added.push(c.getName());
    }
  }
  ibm.setArray(new Float32Array(mats));
  return added;
}

/** Each skinned primitive's JOINTS_0 / WEIGHTS_0 as per-vertex influence lists, and a writer for them (4 kept, renormalised). */
function influences(prim) {
  const J = prim.getAttribute('JOINTS_0'), W = prim.getAttribute('WEIGHTS_0');
  if (!J || !W) return null;
  if (prim.getAttribute('JOINTS_1')) throw new Error('the cloak job handles 4 bones per vertex (the model has JOINTS_1)');
  if (W.getNormalized() || W.getComponentType() !== 5126) throw new Error('the cloak job needs float skin weights');
  const ja = J.getArray(), wa = W.getArray(), n = J.getCount();
  const list = [];
  for (let v = 0; v < n; v++) {
    const m = new Map();
    for (let k = 0; k < 4; k++) if (wa[v * 4 + k] > 0) m.set(ja[v * 4 + k], (m.get(ja[v * 4 + k]) ?? 0) + wa[v * 4 + k]);
    list.push(m);
  }
  const write = () => {
    const nj = new Uint32Array(n * 4), nw = new Float32Array(n * 4);
    list.forEach((m, v) => {
      const top = [...m].filter(([, w]) => w > 1e-6).sort((a, b) => b[1] - a[1]).slice(0, 4);
      const sum = top.reduce((s, [, w]) => s + w, 0) || 1;
      top.forEach(([j, w], k) => { nj[v * 4 + k] = j; nw[v * 4 + k] = w / sum; });
    });
    const most = ja instanceof Uint8Array ? 255 : 65535;
    if (nj.some((j) => j > most)) throw new Error('too many joints for JOINTS_0');
    J.setArray(new (ja.constructor)(nj)); W.setArray(nw);
  };
  return { list, write, positions: prim.getAttribute('POSITION').getArray() };
}

const bindHead = (ibmArr, k) => new Vector3().setFromMatrixPosition(new Matrix4().fromArray(ibmArr, k * 16).invert());

/** Distance from p down to segment a-b, measured below it: how far p hangs under the arm (0 for a point level with it or above). */
function hangBelow(p, a, b) {
  const ab = b.clone().sub(a), t = Math.min(1, Math.max(0, p.clone().sub(a).dot(ab) / Math.max(1e-12, ab.lengthSq())));
  return Math.max(0, a.clone().addScaledVector(ab, t).y - p.y);
}

/**
 * Move the cloth that hangs below each arm onto the arm's cloak copy: a vertex `keep` x height or less below the arm keeps the arm, `free` x
 * height or more moves wholly, smoothly between. Earlier cloak weight is first given back to the arm, so the job can be re-run with new
 * numbers. Returns the vertices that ride the cloak (some of their weight or all).
 */
export function reweightCloak(doc, { keep = ARM_DEFAULTS.keep, free = ARM_DEFAULTS.free } = {}) {
  const skin = skinOf(doc);
  const joints = skin.listJoints();
  const index = new Map(joints.map((j, i) => [j.getName(), i]));
  const ibmArr = skin.getInverseBindMatrices().getArray();
  const prims = doc.getRoot().listNodes().filter((n) => n.getSkin() === skin && n.getMesh()).flatMap((n) => n.getMesh().listPrimitives());
  const sides = SIDES.map((side) => {
    const arm = armOf(skin, side);
    const toCloak = new Map(arm.nodes.map((n) => [index.get(n.getName()), index.get(cloakOf(n.getName()))]));
    if ([...toCloak.values()].some((v) => v === undefined)) throw new Error('add the cloak bones first');
    const line = [arm.ua, arm.fa, arm.hand].map((n) => bindHead(ibmArr, index.get(n.getName())));
    // the hand's own length: as far again past the wrist as the hand's child, or a third of the forearm
    const tip = line[2].clone().addScaledVector(line[2].clone().sub(line[1]), 0.33);
    return { toCloak, back: new Map([...toCloak].map(([a, c]) => [c, a])), line: [...line, tip] };
  });
  const all = prims.map(influences).filter(Boolean);
  let lo = Infinity, hi = -Infinity;
  for (const p of all) for (let i = 1; i < p.positions.length; i += 3) { lo = Math.min(lo, p.positions[i]); hi = Math.max(hi, p.positions[i]); }
  const H = hi - lo;
  let moved = 0;
  for (const p of all) {
    p.list.forEach((m, v) => {
      const pos = new Vector3().fromArray(p.positions, v * 3);
      let any = false;
      for (const s of sides) {
        for (const [c, a] of s.back) if (m.has(c)) { m.set(a, (m.get(a) ?? 0) + m.get(c)); m.delete(c); }
        const arm = [...m.keys()].filter((j) => s.toCloak.has(j));
        if (!arm.length) continue;
        let below = Infinity;
        for (let k = 0; k + 1 < s.line.length; k++) below = Math.min(below, hangBelow(pos, s.line[k], s.line[k + 1]));
        const f = smooth((below - keep * H) / Math.max(1e-9, (free - keep) * H));
        if (f <= 0) continue;
        any = true;
        for (const j of arm) {
          const w = m.get(j), c = s.toCloak.get(j);
          m.set(j, w * (1 - f));
          m.set(c, (m.get(c) ?? 0) + w * f);
        }
      }
      if (any) moved++;
    });
    p.write();
  }
  return moved;
}

// ---------- clips ----------
function sampler(ch) {
  const s = ch.getSampler(), times = s.getInput().getArray(), vals = s.getOutput().getArray();
  const quat = ch.getTargetPath() === 'rotation', n = quat ? 4 : 3, interp = s.getInterpolation();
  if (interp === 'CUBICSPLINE') throw new Error(`clip channel ${ch.getTargetNode().getName()} ${ch.getTargetPath()}: cubic keys are not handled`);
  return {
    times,
    at(t, out) {
      let i = 0;
      while (i < times.length - 1 && times[i + 1] <= t) i++;
      const j = Math.min(i + 1, times.length - 1);
      const k = interp === 'STEP' || times[j] <= times[i] ? 0 : Math.min(1, Math.max(0, (t - times[i]) / (times[j] - times[i])));
      if (quat) return out.fromArray(vals, i * n).slerp(new Quaternion().fromArray(vals, j * n), k);
      return out.fromArray(vals, i * n).lerp(new Vector3().fromArray(vals, j * n), k);
    },
  };
}

/**
 * Swing taking link direction d (unit) down to at most `top` degrees above the chest's level (the plane square to `up`, the chest's own
 * up), eased from `level`; null when it is under. `chestDir` is the link's rest direction carried by the chest: the azimuth a link near
 * `up` takes, where its own is undefined.
 */
export function lowerLink(d, up, chestDir, { level, top }) {
  const lv = level * Math.PI / 180, give = Math.max(1e-3, (top - level) * Math.PI / 180);
  const e = Math.asin(Math.min(1, Math.max(-1, d.dot(up))));
  if (e <= lv) return null;
  const e2 = lv + give * Math.tanh((e - lv) / give);
  const h = d.clone().addScaledVector(up, -d.dot(up)), hl = h.length();
  const fb = chestDir.clone().addScaledVector(up, -chestDir.dot(up));
  const fl = fb.length();
  let az;
  if (fl < 1e-6) az = hl > 1e-9 ? h.divideScalar(hl) : new Vector3(1, 0, 0).addScaledVector(up, -up.x).normalize();
  else {
    const s = smooth(hl / NEAR_UP);
    az = (hl > 1e-9 ? h.divideScalar(hl).multiplyScalar(s) : new Vector3()).addScaledVector(fb.divideScalar(fl), 1 - s);
    if (az.lengthSq() < 1e-12) az = fb.clone();
    az.normalize();
  }
  const d2 = az.multiplyScalar(Math.cos(e2)).addScaledVector(up, Math.sin(e2));
  return new Quaternion().setFromUnitVectors(d, d2.normalize());
}

/** World rotation of a node at time t (the scene's nodes above it at their rest, its ancestors posed by the clip). */
function worldRot(node, local, cache) {
  if (!node) return new Quaternion();
  if (cache.has(node)) return cache.get(node);
  const q = worldRot(node.getParentNode(), local, cache).clone().multiply(local(node, 'rotation'));
  cache.set(node, q);
  return q;
}

function dropChannels(anim, pred) {
  for (const ch of anim.listChannels()) {
    if (!pred(ch)) continue;
    const s = ch.getSampler();
    ch.dispose();
    if (!anim.listChannels().some((c) => c.getSampler() === s)) {
      const used = [s.getInput(), s.getOutput()];
      s.dispose();
      for (const a of used) if (a && !a.listParents().some((p) => p.propertyType !== 'Root')) a.dispose();
    }
  }
}

function addChannel(doc, anim, node, path, times, values, interp = 'LINEAR') {
  const buffer = doc.getRoot().listBuffers()[0];
  const input = doc.createAccessor().setType('SCALAR').setArray(new Float32Array(times)).setBuffer(buffer);
  const output = doc.createAccessor().setType(path === 'rotation' ? 'VEC4' : 'VEC3').setArray(new Float32Array(values)).setBuffer(buffer);
  const s = doc.createAnimationSampler().setInput(input).setOutput(output).setInterpolation(interp);
  anim.addSampler(s);
  anim.addChannel(doc.createAnimationChannel().setTargetNode(node).setTargetPath(path).setSampler(s));
}

/**
 * Key the cloak bones in the named clips (default every clip), replacing their old keys: the arm's own keys, with the upper arm and forearm
 * swung down where they point above the limits. Returns per clip and side the most the upper arm and the forearm were
 * lowered, in degrees.
 */
export function bakeCloak(doc, clips = null, limits = armLimits(doc)) {
  const skin = skinOf(doc);
  const byName = new Map(skin.listJoints().map((j) => [j.getName(), j]));
  const arms = SIDES.map((side) => armOf(skin, side));
  for (const a of arms) if (!byName.has(cloakOf(a.ua.getName()))) throw new Error('add the cloak bones first');
  const L = byName.get('L_CloakUpperarm');
  L.setExtras({ ...L.getExtras(), cloak: { level: limits.level, top: limits.top, keep: limits.keep, free: limits.free } });
  const report = {};
  for (const anim of doc.getRoot().listAnimations()) {
    if (clips && !clips.includes(anim.getName())) continue;
    dropChannels(anim, (ch) => isCloakBone(ch.getTargetNode()?.getName() ?? ''));
    const chans = new Map();
    for (const ch of anim.listChannels()) chans.set(`${ch.getTargetNode().getName()}.${ch.getTargetPath()}`, ch);
    const samplers = new Map();
    const local = (t) => (node, path) => {
      const key = `${node.getName()}.${path}`;
      if (!chans.has(key)) return path === 'rotation' ? new Quaternion().fromArray(node.getRotation()) : new Vector3().fromArray(path === 'translation' ? node.getTranslation() : node.getScale());
      if (!samplers.has(key)) samplers.set(key, sampler(chans.get(key)));
      return samplers.get(key).at(t, path === 'rotation' ? new Quaternion() : new Vector3());
    };
    const said = {};
    for (const [si, arm] of arms.entries()) {
      // the times that decide the arm's direction: every key of the upper arm, forearm and hand rotations and translations and of the bones above
      const above = [];
      for (let n = arm.fa; n; n = n.getParentNode()) above.push(n);
      const times = new Set();
      for (const n of [...above, arm.hand]) for (const p of ['rotation', 'translation']) chans.get(`${n.getName()}.${p}`)?.getSampler().getInput().getArray().forEach((t) => times.add(t));
      const ts = [...times].sort((a, b) => a - b);
      // the rest directions of the two links in the chest's frame (the azimuth a near-vertical link falls back on)
      const restLocal = (node, path) => path === 'rotation' ? new Quaternion().fromArray(node.getRotation()) : new Vector3().fromArray(node.getTranslation());
      const rc = new Map();
      const chestRest = worldRot(arm.chest, restLocal, rc).clone().invert();   // the chest's rest frame: its up is the world's
      const restIn = (link, child) => new Vector3().fromArray(child.getTranslation()).applyQuaternion(worldRot(link, restLocal, rc)).normalize().applyQuaternion(chestRest);
      const rest = [restIn(arm.ua, arm.fa), restIn(arm.fa, arm.hand)];
      const ua = [], fa = [];
      const most = [0, 0];   // the most the upper arm and the forearm are lowered (radians)
      for (const t of ts) {
        const lt = local(t), cache = new Map();
        const chest = worldRot(arm.chest, lt, cache), clav = worldRot(arm.clavicle, lt, cache);
        const uaW = worldRot(arm.ua, lt, cache), faW = worldRot(arm.fa, lt, cache);
        const d1 = lt(arm.fa, 'translation').applyQuaternion(uaW).normalize(), d2 = lt(arm.hand, 'translation').applyQuaternion(faW).normalize();
        const up = UP.clone().applyQuaternion(chestRest).applyQuaternion(chest);
        const r1 = lowerLink(d1, up, rest[0].clone().applyQuaternion(chest), limits), r2 = lowerLink(d2, up, rest[1].clone().applyQuaternion(chest), limits);
        const c1 = r1 ? r1.clone().multiply(uaW) : uaW.clone(), c2 = r2 ? r2.clone().multiply(faW) : faW.clone();
        [r1, r2].forEach((r, k) => { if (r) most[k] = Math.max(most[k], 2 * Math.acos(Math.min(1, Math.abs(r.w)))); });
        ua.push(...clav.clone().invert().multiply(c1).normalize().toArray());
        fa.push(...c1.clone().invert().multiply(c2).normalize().toArray());
      }
      said[SIDES[si]] = most.map((m) => Math.round(m * 180 / Math.PI));
      for (const n of arm.nodes) {
        const c = byName.get(cloakOf(n.getName()));
        for (const path of ['translation', 'rotation', 'scale']) {
          const own = chans.get(`${n.getName()}.${path}`);
          if (path === 'rotation' && (n === arm.ua || n === arm.fa) && most[0] + most[1] > 0) {
            for (let i = 4; i < (n === arm.ua ? ua : fa).length; i += 4) {   // one hemisphere, so slerp takes the short way
              const q = n === arm.ua ? ua : fa;
              if (q[i] * q[i - 4] + q[i + 1] * q[i - 3] + q[i + 2] * q[i - 2] + q[i + 3] * q[i - 1] < 0) for (let k = 0; k < 4; k++) q[i + k] = -q[i + k];
            }
            addChannel(doc, anim, c, path, ts, n === arm.ua ? ua : fa);
          } else if (own) {   // the arm's own keys: the same accessors, so the copy costs no key data
            const s = own.getSampler();
            const shared = doc.createAnimationSampler().setInput(s.getInput()).setOutput(s.getOutput()).setInterpolation(s.getInterpolation());
            anim.addSampler(shared);
            anim.addChannel(doc.createAnimationChannel().setTargetNode(c).setTargetPath(path).setSampler(shared));
          }
        }
      }
    }
    report[anim.getName()] = said;
  }
  return report;
}

// ---------- the back: a cape that hangs ----------
/** Bind-space facts the cape needs: height, forward (the feet's way), and the body's middle line (spine above the hips, between the legs below). */
function bodyOf(doc) {
  const skin = skinOf(doc);
  const joints = skin.listJoints();
  const ibmArr = skin.getInverseBindMatrices().getArray();
  const at = (n) => { const k = joints.findIndex((j) => j.getName() === n); if (k < 0) throw new Error(`the cape needs the shared biped skeleton (no ${n})`); return bindHead(ibmArr, k); };
  const fwd = new Vector3();
  for (const s of SIDES) fwd.add(at(`${s}_ToeBase`).sub(at(`${s}_Foot`)));
  fwd.y = 0; fwd.normalize();
  const mid = (a) => at(`L_${a}`).add(at(`R_${a}`)).multiplyScalar(0.5);
  const line = [at('Head'), at('NeckTwist01'), at('Spine02'), at('Spine01'), at('Waist'), mid('Thigh'), mid('Calf'), mid('Foot')];
  const prims = doc.getRoot().listNodes().filter((n) => n.getSkin() === skin && n.getMesh()).flatMap((n) => n.getMesh().listPrimitives());
  let lo = Infinity, hi = -Infinity;
  for (const p of prims) { const a = p.getAttribute('POSITION').getArray(); for (let i = 1; i < a.length; i += 3) { lo = Math.min(lo, a[i]); hi = Math.max(hi, a[i]); } }
  /** The middle line's point at height y. */
  const lineAt = (y) => {
    if (y >= line[0].y) return line[0].clone();
    for (let k = 0; k + 1 < line.length; k++) {
      const a = line[k], b = line[k + 1];
      if (y <= a.y && y >= b.y) return a.clone().lerp(b, a.y - b.y > 1e-9 ? (a.y - y) / (a.y - b.y) : 0);
    }
    return line[line.length - 1].clone();
  };
  return { skin, joints, ibmArr, at, fwd, lineAt, prims, lo, H: hi - lo };
}

/** How far behind the body's middle line a bind-space point is, as a share of the height. */
const behind = (body, p) => (body.lineAt(p.y).dot(body.fwd) - p.dot(body.fwd)) / body.H;

/**
 * Add the cape (once): a chain Cape01..Cape04 under Spine02 down the middle of the back cloth, from the chest's height to the hem, each joint
 * in the cloth's depth at its height. Returns the names added.
 */
export function addCape(doc, { keep = CAPE_DEFAULTS.keep, free = CAPE_DEFAULTS.free } = {}) {
  const body = bodyOf(doc);
  if (body.joints.some((j) => j.getName() === CAPE[0])) return [];
  const pts = [];
  for (const p of body.prims) {
    const a = p.getAttribute('POSITION').getArray();
    for (let i = 0; i < a.length; i += 3) { const v = new Vector3(a[i], a[i + 1], a[i + 2]); if (behind(body, v) > free) pts.push(v); }
  }
  if (pts.length < 50) throw new Error('no cloth hangs behind this body: it needs no cape');
  const top = body.at('Spine02').y, hem = Math.min(...pts.map((v) => v.y)) + 0.02 * body.H;
  const side = new Vector3().crossVectors(body.fwd, UP).normalize();
  const heads = CAPE.map((_, k) => {
    const y = top + (hem - top) * k / (CAPE.length - 1);
    const c = body.lineAt(y);
    const band = pts.filter((v) => Math.abs(v.y - y) < 0.05 * body.H && Math.abs(v.clone().sub(c).dot(side)) < 0.15 * body.H).map((v) => behind(body, v)).sort((x, z) => x - z);
    const depth = k === 0 || !band.length ? keep : band[Math.floor(band.length / 2)];
    return c.addScaledVector(body.fwd, -depth * body.H).setY(y);
  });
  // world = G x mesh space (Tripo's binds carry a scale): G from Spine02's rest world matrix and its bind
  const worldOf = (n) => { const m = new Matrix4(); for (let x = n; x; x = x.getParentNode()) m.premultiply(new Matrix4().compose(new Vector3().fromArray(x.getTranslation()), new Quaternion().fromArray(x.getRotation()), new Vector3().fromArray(x.getScale()))); return m; };
  const spine = body.joints.find((j) => j.getName() === 'Spine02');
  const k02 = body.joints.indexOf(spine);
  const G = worldOf(spine).multiply(new Matrix4().fromArray(body.ibmArr, k02 * 16));
  const mats = Array.from(body.ibmArr);
  let parent = spine;
  const added = [];
  heads.forEach((h, k) => {
    const pw = worldOf(parent);
    const local = h.clone().applyMatrix4(G).applyMatrix4(pw.clone().invert());
    const n = doc.createNode(CAPE[k]).setTranslation(local.toArray());
    parent.addChild(n);
    body.skin.addJoint(n);
    mats.push(...worldOf(n).invert().multiply(G).toArray());
    added.push(CAPE[k]);
    parent = n;
  });
  body.skin.getInverseBindMatrices().setArray(new Float32Array(mats));
  return added;
}

/**
 * Move the cloth hanging behind the body onto the cape: `keep` x height or less behind the middle line keeps its bones (the robe on the legs,
 * the back), `free` or more rides the cape wholly, by its height along the chain (each link, blended into the next at the joints).
 */
export function reweightCape(doc, { keep = CAPE_DEFAULTS.keep, free = CAPE_DEFAULTS.free } = {}) {
  const body = bodyOf(doc);
  const index = new Map(body.joints.map((j, i) => [j.getName(), i]));
  if (!index.has(CAPE[0])) throw new Error('add the cape first');
  const heads = CAPE.map((n) => bindHead(body.ibmArr, index.get(n)));
  const links = CAPE.slice(0, -1).map((n) => index.get(n));
  let moved = 0;
  for (const p of body.prims.map(influences).filter(Boolean)) {
    p.list.forEach((m, v) => {
      const pos = new Vector3().fromArray(p.positions, v * 3);
      for (const j of links) if (m.has(j)) m.delete(j);   // a re-run starts from the body's own weights (renormalised by the writer)
      const f = smooth((behind(body, pos) - keep) / (free - keep)) * smooth((heads[0].y - pos.y) / (0.04 * body.H));
      if (f <= 0) return;
      // where along the chain: the segment whose height span holds it (above the first: the first; below the last: the last)
      let k = 0;
      while (k < links.length - 1 && pos.y < heads[k + 1].y) k++;
      const u = Math.min(1, Math.max(0, (heads[k].y - pos.y) / Math.max(1e-9, heads[k].y - heads[k + 1].y)));
      const w = new Map([[links[k], 1]]);
      if (k > 0 && u < 0.5) { const b = 0.5 * (1 - smooth(u / 0.5)); w.set(links[k - 1], b); w.set(links[k], 1 - b); }
      if (k < links.length - 1 && u > 0.5) { const b = 0.5 * smooth((u - 0.5) / 0.5); w.set(links[k + 1], b); w.set(links[k], 1 - b); }
      const sum = [...m.values()].reduce((a, b) => a + b, 0) || 1;
      for (const [j, x] of m) m.set(j, (x / sum) * (1 - f));
      for (const [j, x] of w) m.set(j, (m.get(j) ?? 0) + x * f);
      moved++;
    });
    p.write();
  }
  return moved;
}

/**
 * Key the cape in the named clips (default every clip), replacing its old keys: carried by the chest, each link at most `lift` (+`give`) degrees
 * above its rest hang. Returns per clip the most a link was swung down, in degrees.
 */
export function bakeCape(doc, clips = null, limits = capeLimits(doc)) {
  const { lift, give } = limits;
  const skin = skinOf(doc);
  const byName = new Map(skin.listJoints().map((j) => [j.getName(), j]));
  const cape = CAPE.map((n) => byName.get(n));
  if (cape.some((n) => !n)) throw new Error('add the cape first');
  cape[0].setExtras({ ...cape[0].getExtras(), cape: { keep: limits.keep, free: limits.free, lift, give } });
  const chest = cape[0].getParentNode();
  const restLocal = (node, path) => path === 'rotation' ? new Quaternion().fromArray(node.getRotation()) : new Vector3().fromArray(node.getTranslation());
  const rc = new Map();
  const bindDir = cape.slice(0, -1).map((n, k) => new Vector3().fromArray(cape[k + 1].getTranslation()).applyQuaternion(worldRot(n, restLocal, rc)).normalize());
  const bindElev = bindDir.map((d) => Math.asin(d.y) * 180 / Math.PI);
  const chestRest = worldRot(chest, restLocal, rc).clone().invert();
  const report = {};
  for (const anim of doc.getRoot().listAnimations()) {
    if (clips && !clips.includes(anim.getName())) continue;
    dropChannels(anim, (ch) => CAPE.includes(ch.getTargetNode()?.getName() ?? ''));
    const chans = new Map();
    for (const ch of anim.listChannels()) chans.set(`${ch.getTargetNode().getName()}.${ch.getTargetPath()}`, ch);
    const samplers = new Map();
    const local = (t) => (node, path) => {
      const key = `${node.getName()}.${path}`;
      if (!chans.has(key)) return restLocal(node, path);
      if (!samplers.has(key)) samplers.set(key, sampler(chans.get(key)));
      return samplers.get(key).at(t, path === 'rotation' ? new Quaternion() : new Vector3());
    };
    const times = new Set();
    for (let n = chest; n; n = n.getParentNode()) chans.get(`${n.getName()}.rotation`)?.getSampler().getInput().getArray().forEach((t) => times.add(t));
    const ts = [...times].sort((a, b) => a - b);
    if (!ts.length) { report[anim.getName()] = 0; continue; }   // the chest never turns: the cape hangs at rest
    const keys = cape.slice(0, -1).map(() => []);
    let most = 0;
    for (const t of ts) {
      const lt = local(t), cache = new Map();
      let parentW = worldRot(chest, lt, cache);
      const chestW = parentW.clone();
      cape.slice(0, -1).forEach((n, k) => {
        const carried = parentW.clone().multiply(restLocal(n, 'rotation'));
        const d = new Vector3().fromArray(cape[k + 1].getTranslation()).applyQuaternion(carried).normalize();
        const level = bindElev[k] + lift;
        const r = lowerLink(d, UP, bindDir[k].clone().applyQuaternion(chestRest).applyQuaternion(chestW), { level, top: level + give });
        const w = r ? r.clone().multiply(carried) : carried;
        if (r) most = Math.max(most, 2 * Math.acos(Math.min(1, Math.abs(r.w))));
        keys[k].push(...parentW.clone().invert().multiply(w).normalize().toArray());
        parentW = w;
      });
    }
    keys.forEach((q, k) => {
      for (let i = 4; i < q.length; i += 4) if (q[i] * q[i - 4] + q[i + 1] * q[i - 3] + q[i + 2] * q[i - 2] + q[i + 3] * q[i - 1] < 0) for (let c = 0; c < 4; c++) q[i + c] = -q[i + c];
      addChannel(doc, anim, cape[k], 'rotation', ts, q);
    });
    report[anim.getName()] = Math.round(most * 180 / Math.PI);
  }
  return report;
}

/**
 * The job step: the arm cloak (`arms`, default on) and the cape (`cape`, default off), each its bones (once), its weights and every clip.
 * `top` and `lift` override the saved or default limits. A part the model has keeps it (a re-run re-tunes it). Returns what was added and
 * moved and, per part, the most each clip was lowered.
 */
export function cloakModel(doc, { arms = true, cape = false, top, lift } = {}) {
  if (!arms && !cape) throw new Error('the cloak job needs arms or cape');
  const out = { added: [], arms: null, cape: null };
  if (arms) {
    const limits = { ...armLimits(doc), ...(top !== undefined ? { top } : {}) };
    if (!(limits.top > limits.level)) throw new Error(`top must be above ${limits.level} degrees`);
    out.added.push(...addCloakBones(doc));
    out.arms = { moved: reweightCloak(doc, limits), clips: bakeCloak(doc, null, limits) };
  }
  if (cape) {
    const limits = { ...capeLimits(doc), ...(lift !== undefined ? { lift } : {}) };
    out.added.push(...addCape(doc, limits));
    out.cape = { moved: reweightCape(doc, limits), clips: bakeCape(doc, null, limits) };
  }
  return out;
}

/** Re-key the cloak parts the model has in these clips (after a step changed them), with the settings saved in the file. */
export function rebakeCloak(doc, clips) {
  const names = new Set(doc.getRoot().listNodes().map((n) => n.getName()));
  return {
    arms: names.has('L_CloakUpperarm') ? bakeCloak(doc, clips) : null,
    cape: names.has(CAPE[0]) ? bakeCape(doc, clips) : null,
  };
}
