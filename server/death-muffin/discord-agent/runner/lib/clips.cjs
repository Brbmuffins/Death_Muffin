'use strict';
// The agent's short-video request for a team PC (.dm-clip.json) and the shot plan it leaves for team pictures (.dm-shot.json).
// Everything here is deterministic runner code: the agent only writes the files, the runner validates them before anything goes to a team PC.
//
//   .dm-clip.json = { "plan":     { "discipline": "reaper", "equip": [<item id>...], "clips": [{ "name", "area", "cast", "at", "enemies", "seconds", "camera", "equip" }, ...] },
//                     "variants": [{ "label", "title", "tune": { "<DmDb path>": { <nested keys>: <value> } } }, ...] }
//
// The plan is the game's own clip plan (client QA driver, `--clip-plan`); a variant is one game run with its tune merged over the game's data
// (`--tune`), so the clips show the options side by side. The game refuses a tune key that does not exist, so a typo never silently does nothing.
// A model preview is a clip too: camera "turntable" (the hero stands in the game's light and turns; no rite is cast, so `cast` may be left out) on a hero that
// wears the items of `equip` (the plan's list is for every clip, a clip's own list replaces it for that clip), written with one variant and an empty tune.
// A model clip films one creature's model alone instead of the hero (the recorder's model view, client/main/CLIPS.md "Model clips"): "model" is its row id of
// client/game/view_models.json, as the job's branch has it (a Blender job's changed model is seen as it ships), with "anim" (a clip of the model), "turn",
// "height", and "move" (it walks along the ground at its stride's speed, or "speed" m/s, so sliding feet show; camera "still" walks it past a camera that
// stays put). It casts nothing, so `cast` may be left out.
//
// A clip may carry `setup` (how the scene is set before recording) and `steps` (what happens when): lists of {"do": "<word>", ...its arguments}, a step
// also with "at" (seconds into the clip). A shot of the shot plan may carry the same two lists, a step's "at" then before the shot's wait ends. The words and
// their arguments are the game's (client/main/qa_clip_steps.json), read from the job's own branch: a new word is a game change the agent makes in its branch
// (the handler, the list, a test), and its videos and pictures can use it at once. The runner checks a request against that list (known words, known
// arguments, their types and ranges); the recorder checks it again and carries it out.
//
// The shot plan (.dm-shot.json) may carry `resolutions`: the screen sizes a team PC renders every shot at (default: the one standard size), `before`: true to
// render the unchanged game too (BEFORE and AFTER pairs), and `presets`: the graphics presets (default Ultra alone). By default a shot is one AFTER picture on
// Ultra (Helix, 2026-10-20: "sometimes only 1 high quality screenshot is required"). All three are checked here.
const fs = require('fs');
const path = require('path');

const CLIP_FILE = '.dm-clip.json';
const MAX_BYTES = 32 * 1024;
const MAX_VARIANTS = 4, MAX_CLIPS = 4, MAX_SECONDS = 8, MAX_ENEMIES = 12, MAX_TITLE = 60, MAX_EQUIP = 12;
const MAX_TUNE_DEPTH = 6, MAX_TUNE_LEAVES = 64, MAX_TUNE_TEXT = 100;
const LABEL_RE = /^[a-z0-9][a-z0-9-]{0,23}$/;           // a variant's label: the first half of the uploaded file's name
const CLIP_NAME_RE = /^[a-z0-9][a-z0-9-]{0,29}$/;       // no underscore: `<label>_<clip>` splits at the first one
const AREA_RE = /^[a-z0-9_-]{1,40}$/, CAST_RE = /^[a-z0-9_]{1,60}$/, ITEM_RE = /^[a-z0-9_]{1,60}$/;
const CAMERAS = ['follow', 'wide', 'turntable', 'still'];
const STEPS_FILE = 'client/main/qa_clip_steps.json';
const MODELS_FILE = 'client/game/view_models.json';   // the model rows a model clip names, read from the job's branch
const MAX_SETUP = 12, MAX_STEPS = 24;
const SHOT_WAIT_MS = 300, MAX_SHOT_WAIT_MS = 5000;   // a shot's wait when "wait_ms" is left out, and its most (main/qa_ui_shots.gd)
const WORD_RE = /^[a-z][a-z0-9_]{0,23}$/, ENEMY_RE = /^[a-z0-9_]{1,40}$/;
const MODEL_RE = /^[a-z0-9_]{1,60}$/, ANIM_RE = /^[A-Za-z0-9_.|-]{1,48}$/;
// The screen sizes a shot plan may ask for (a team PC renders each shot at every size listed; with none the team app's standard 1920x1080 is used).
const RESOLUTIONS = ['1920x1080', '2560x1440', '3840x2160', '3440x1440'];
// The graphics presets a shot plan may ask for, lowest first (the team app knows these four); with none, Ultra alone.
const SHOT_PRESETS = ['low', 'medium', 'high', 'ultra'], SHOT_PRESETS_DEFAULT = ['ultra'];
const TUNE_KEY_RE = /^[A-Za-z0-9_][A-Za-z0-9_./-]{0,79}$/;
const BAD_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
// Playable disciplines by name -> class index (client/data/combat/disciplines.json by_index; the shot plan and the clip plan name one the same way).
const CLASSES = { ossuary: 1, gravecaller: 2, mourner: 3, rotweaver: 4, reaper: 11 };
// The scene words' limits (main/qa_ui_shots.gd: MAX_LEGION, MAX_THRALLS, its stand-in spots; main/qa_scene.gd: a walk of at most 8 points); the game checks them again.
const MAX_LEGION = 2, MAX_THRALLS = 40, MAX_OWNERS = 4, MAX_PATH = 8, MAX_COORD = 500;
const KIND_RE = /^[a-z_]{1,24}$/, GROUP_RE = /^[a-z]{1,16}$/;
const isPoint = (v) => Array.isArray(v) && v.length === 2 && v.every((n) => typeof n === 'number' && Number.isFinite(n) && Math.abs(n) <= MAX_COORD);
// A plan's `discipline` ("reaper", "hero_reaper" or a class index) -> its class index; 0 = not a playable discipline.
function classOf(d) {
  if (typeof d === 'string') return CLASSES[d.toLowerCase().replace(/^hero_/, '')] || 0;
  return Object.values(CLASSES).includes(d) ? d : 0;
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const onlyKeys = (o, keys, where, errs) => { for (const k of Object.keys(o)) if (!keys.includes(k)) errs.push(`${where} has an unknown field "${k}" (allowed: ${keys.join(', ')})`); };

// The values a tune may set: text, numbers and true/false, in nested objects; the keys are data paths and keys that must already exist in the game's data
// (the game checks that; the runner only keeps the shape small and plain).
function checkTune(tune, where, errs) {
  if (!isObj(tune)) { errs.push(`${where}: "tune" must be an object like {"combat/abilities": {"haunting_wraith": {"speed": 4}}} (empty {} runs the game as it is)`); return; }
  let leaves = 0;
  const walk = (o, depth, trail) => {
    if (depth > MAX_TUNE_DEPTH) { errs.push(`${where}: "tune" nests deeper than ${MAX_TUNE_DEPTH} levels at ${trail}`); return; }
    for (const [k, v] of Object.entries(o)) {
      const at = trail ? `${trail}.${k}` : k;
      if (BAD_KEYS.has(k) || !TUNE_KEY_RE.test(k)) { errs.push(`${where}: "${k}" is not a data key (letters, digits, _ . / - only)`); continue; }
      if (isObj(v)) walk(v, depth + 1, at);
      else if (typeof v === 'number') { if (!Number.isFinite(v)) errs.push(`${where}: ${at} must be a finite number`); else leaves++; }
      else if (typeof v === 'boolean') leaves++;
      else if (typeof v === 'string') { if (v.length > MAX_TUNE_TEXT || /[\u0000-\u001f\u007f]/.test(v)) errs.push(`${where}: ${at} is text over ${MAX_TUNE_TEXT} characters or with control characters`); else leaves++; }
      else errs.push(`${where}: ${at} must be a number, text or true/false (a list or null cannot be tuned; write a colour as the data file does, as text, or as its own keys)`);
    }
  };
  walk(tune, 1, '');
  if (leaves > MAX_TUNE_LEAVES) errs.push(`${where}: "tune" sets ${leaves} values (at most ${MAX_TUNE_LEAVES})`);
}

// A list of item ids the hero wears (the ids of client/data/content, such as set_gravecaller_chest). The game skips one it does not know and says so.
function checkEquip(list, where, errs) {
  if (!Array.isArray(list) || list.length < 1 || list.length > MAX_EQUIP || list.some((x) => typeof x !== 'string' || !ITEM_RE.test(x))) errs.push(`${where}: "equip" must be a list of 1 to ${MAX_EQUIP} item ids (lowercase letters, digits and _), e.g. ["set_gravecaller_chest", "staff_moon"]`);
  else if (new Set(list).size !== list.length) errs.push(`${where}: "equip" names an item twice`);
}

// The game's list of setup and step words in the job's branch (STEPS_FILE): { setup: {word: {args: {name: {type, min, max, required}}}}, steps: {...} }, or null.
function readVocabulary(wt) {
  try {
    const f = path.join(wt, STEPS_FILE), st = fs.lstatSync(f);
    if (!st.isFile() || st.size > MAX_BYTES) return null;
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    return isObj(j) && isObj(j.setup) && isObj(j.steps) ? j : null;
  } catch { return null; }
}

// The model rows in the job's branch (MODELS_FILE): {<id>: {clips: [...], ...}}, or null when the file cannot be read (the recorder checks the id then).
function readModelRows(wt) {
  try {
    const f = path.join(wt, MODELS_FILE), st = fs.lstatSync(f);
    if (!st.isFile() || st.size > 4 * 1024 * 1024) return null;
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    return isObj(j) ? j : null;
  } catch { return null; }
}

// One argument against the game's description of it: '' when it fits, else why not (after its name).
function argRefusal(v, spec) {
  switch (spec && spec.type) {
    case 'bool': return typeof v === 'boolean' ? '' : 'must be true or false';
    case 'number':
      if (typeof v !== 'number' || !Number.isFinite(v)) return 'must be a number';
      if ((typeof spec.min === 'number' && v < spec.min) || (typeof spec.max === 'number' && v > spec.max)) return `must be from ${spec.min} to ${spec.max}`;
      return '';
    case 'rite': return typeof v === 'string' && CAST_RE.test(v) ? '' : 'must be a rite id such as haunting_wraith';
    case 'enemy': return typeof v === 'string' && ENEMY_RE.test(v) ? '' : 'must be an enemy id such as robber';
    case 'point': return isPoint(v) ? '' : 'must be a point [x, z] of the area';
    case 'path': return isPoint(v) || (Array.isArray(v) && v.length >= 1 && v.length <= MAX_PATH && v.every(isPoint)) ? '' : `must be a point [x, z] or a list of 1 to ${MAX_PATH} of them`;
    case 'owners': {
      if (!isObj(v) || !Object.keys(v).length || Object.keys(v).length > MAX_OWNERS) return `must be {"mine": [kinds], "<discipline>": [kinds]} with 1 to ${MAX_OWNERS} owners`;
      let n = 0;
      for (const [who, kinds] of Object.entries(v)) {
        if (who !== 'mine' && !CLASSES[who]) return `names an owner that is not "mine" or a discipline (${Object.keys(CLASSES).join(', ')})`;
        if (!Array.isArray(kinds) || !kinds.length || kinds.some((k) => typeof k !== 'string' || !KIND_RE.test(k))) return 'must give each owner a list of thrall kinds such as warrior';
        n += kinds.length;
      }
      return n <= MAX_THRALLS ? '' : `raises ${n} thralls (at most ${MAX_THRALLS})`;
    }
    case 'candle_group': return typeof v === 'string' && GROUP_RE.test(v) ? '' : 'must be a candle group such as west';
    default: return `has a type the runner cannot check (${spec && spec.type}): fix ${STEPS_FILE}`;
  }
}

// A clip's or a shot's `setup` or `steps` against the vocabulary. `seconds` is the clip's length (a step's `at` from 0 to it) or, for a shot (`shot` true), the wait's length
// (an `at` from 0 to before it: the picture is taken when the wait ends). Returns whether the steps cast a rite (a clip that does needs no `cast`).
function checkWords(list, section, voc, seconds, w, errs, shot = false) {
  if (!Array.isArray(list)) { errs.push(`${w}: "${section}" must be a list of {"do": ...} objects`); return false; }
  const cap = section === 'setup' ? MAX_SETUP : MAX_STEPS;
  if (list.length > cap) { errs.push(`${w}: "${section}" has ${list.length} entries (at most ${cap})`); return false; }
  const words = (voc && voc[section]) || {};
  let casts = false;
  list.forEach((e, i) => {
    const at = `${w} ${section} ${i + 1}`;
    if (!isObj(e)) { errs.push(`${at} must be an object`); return; }
    const word = e.do;
    if (typeof word !== 'string' || !WORD_RE.test(word) || !isObj(words[word])) { errs.push(`${at}: "do" must be one of ${Object.keys(words).join(', ')} (${STEPS_FILE})`); return; }
    const args = isObj(words[word].args) ? words[word].args : {};
    if (section === 'steps') {
      if (typeof e.at !== 'number' || !(e.at >= 0 && (shot ? e.at < seconds : e.at <= seconds))) {
        errs.push(`${at} (${word}): "at" must be a number of seconds from 0 to ${shot ? `before the shot's wait of ${seconds} (the picture is taken when it ends; "wait_ms" is the wait)` : `the clip's ${seconds}`}`);
      }
      if (word === 'cast') casts = true;
    }
    for (const [k, v] of Object.entries(e)) {
      if (k === 'do' || (k === 'at' && section === 'steps')) continue;
      if (!Object.prototype.hasOwnProperty.call(args, k)) { errs.push(`${at} (${word}) has an unknown argument "${k}" (it takes: ${Object.keys(args).join(', ') || 'nothing'})`); continue; }
      const why = argRefusal(v, args[k]);
      if (why) errs.push(`${at} (${word}): "${k}" ${why}`);
    }
    for (const [k, spec] of Object.entries(args)) if (isObj(spec) && spec.required === true && e[k] === undefined) errs.push(`${at} (${word}) needs "${k}"`);
  });
  return casts;
}

function checkPlan(plan, errs, wt) {
  if (!isObj(plan)) { errs.push('"plan" must be an object {"discipline": "reaper", "clips": [...]}'); return null; }
  onlyKeys(plan, ['discipline', 'equip', 'legion', 'clips'], '"plan"', errs);
  if (plan.legion !== undefined && (!Array.isArray(plan.legion) || plan.legion.length < 1 || plan.legion.length > MAX_LEGION || plan.legion.some((x) => typeof x !== 'string' || !ITEM_RE.test(x)))) {
    errs.push(`"plan.legion" must be a list of 1 to ${MAX_LEGION} item ids: the hero's Legion kit, one armour piece and one weapon`);
  }
  if (!classOf(plan.discipline)) errs.push(`"plan.discipline" must be one of ${Object.keys(CLASSES).join(', ')}`);
  if (plan.equip !== undefined) checkEquip(plan.equip, '"plan"', errs);
  if (!Array.isArray(plan.clips) || plan.clips.length < 1 || plan.clips.length > MAX_CLIPS) { errs.push(`"plan.clips" must be a list of 1 to ${MAX_CLIPS} clips`); return null; }
  const names = new Set();
  let voc;   // read from the branch only when a clip has setup or steps
  let rows;  // and the model rows only when a clip names a model
  plan.clips.forEach((c, i) => {
    const w = `clip ${i + 1}`;
    if (!isObj(c)) { errs.push(`${w} must be an object`); return; }
    onlyKeys(c, ['name', 'area', 'cast', 'at', 'enemies', 'seconds', 'camera', 'equip', 'setup', 'steps', 'model', 'anim', 'turn', 'height', 'move', 'speed'], w, errs);
    const model = c.model !== undefined;
    if (model) {
      if (rows === undefined) rows = readModelRows(wt);
      checkModel(c, w, errs, rows);
    }
    else if (['anim', 'turn', 'height', 'move', 'speed'].some((k) => c[k] !== undefined) || c.camera === 'still') errs.push(`${w}: "anim", "turn", "height", "move", "speed" and camera "still" are for a model clip (one with "model")`);
    let stepCasts = false;
    if (c.setup !== undefined || c.steps !== undefined) {
      if (voc === undefined) voc = readVocabulary(wt);
      if (!voc) errs.push(`${w}: this branch's game has no list of setup and step words (${STEPS_FILE}): merge the latest main first`);
      else {
        const secs = typeof c.seconds === 'number' && c.seconds > 0 && c.seconds <= MAX_SECONDS ? c.seconds : (c.camera === 'turntable' || model ? 6 : 5);
        if (c.setup !== undefined) checkWords(c.setup, 'setup', voc, secs, w, errs);
        if (c.steps !== undefined) stepCasts = checkWords(c.steps, 'steps', voc, secs, w, errs);
      }
    }
    if (typeof c.name !== 'string' || !CLIP_NAME_RE.test(c.name)) errs.push(`${w}: "name" must be lowercase letters, digits and dashes (1 to 30 characters, no underscore)`);
    else if (names.has(c.name)) errs.push(`${w}: the name "${c.name}" is used twice`); else names.add(c.name);
    if (c.area !== undefined && (typeof c.area !== 'string' || !AREA_RE.test(c.area))) errs.push(`${w}: "area" must be an area id such as graves (the Hollow Graves when left out)`);
    // a turntable clip casts nothing, so it needs no rite; nor does a scene (thralls raised, or steps other than casts: a walk, the candles)
    const scene = (Array.isArray(c.setup) && c.setup.some((e) => isObj(e) && e.do === 'thralls')) || (Array.isArray(c.steps) && c.steps.some((e) => isObj(e) && e.do !== 'cast'));
    if (c.cast === undefined && (c.camera === 'turntable' || model || stepCasts || scene)) { /* a model preview, the steps cast, or a scene */ }
    else if (typeof c.cast !== 'string' || !CAST_RE.test(c.cast)) errs.push(`${w}: "cast" must be a rite id such as haunting_wraith (only a "turntable" or model clip, one whose steps cast, or a scene of thralls or walks may leave it out)`);
    if (c.at !== undefined && c.at !== 'pack' && c.at !== 'ahead') errs.push(`${w}: "at" must be "pack" or "ahead"`);
    if (c.camera !== undefined && !CAMERAS.includes(c.camera)) errs.push(`${w}: "camera" must be "follow", "wide", "turntable" or "still" (a model clip)`);
    if (c.equip !== undefined) checkEquip(c.equip, w, errs);
    if (c.enemies !== undefined && !(Number.isInteger(c.enemies) && c.enemies >= 0 && c.enemies <= MAX_ENEMIES)) errs.push(`${w}: "enemies" must be a whole number from 0 to ${MAX_ENEMIES}`);
    if (c.seconds !== undefined && !(typeof c.seconds === 'number' && c.seconds > 0 && c.seconds <= MAX_SECONDS)) errs.push(`${w}: "seconds" must be a number above 0 and at most ${MAX_SECONDS} (5 when left out)`);
  });
  return plan;
}

// A model clip's own fields (the recorder checks them again, with the model's row: an unknown id, or a "move" with no stride and no "speed", fails the clip there).
// `rows`: the branch's model rows (null = unread: only the id's form is checked here). An id it lacks, or an "anim" its row's clips lack, is refused with the ids or clips there are.
function checkModel(c, w, errs, rows) {
  if (typeof c.model !== 'string' || !MODEL_RE.test(c.model)) { errs.push(`${w}: "model" must be a model row id of ${MODELS_FILE}, such as skull_rat`); return; }
  const row = rows ? rows[c.model] : undefined;
  if (rows && !isObj(row)) {
    const near = Object.keys(rows).filter((k) => k.includes(c.model) || c.model.includes(k)).slice(0, 6);
    errs.push(`${w}: no model row "${c.model}" in ${MODELS_FILE}${near.length ? ` (did you mean ${near.join(', ')}?)` : ''}`);
  }
  if (c.anim !== undefined && (typeof c.anim !== 'string' || !ANIM_RE.test(c.anim))) errs.push(`${w}: "anim" must be a clip name of the model, such as walk`);
  else if (c.anim !== undefined && isObj(row) && Array.isArray(row.clips) && !row.clips.includes(c.anim)) errs.push(`${w}: the model ${c.model} has no clip "${c.anim}" (it has: ${row.clips.join(', ')})`);
  if (c.camera === 'wide') errs.push(`${w}: a model clip's "camera" is "follow" (one side), "still" (one side, the camera not moving) or "turntable"`);
  for (const [k, lo, hi] of [['turn', -360, 360], ['height', 0.1, 30], ['speed', 0, 15]]) {
    if (c[k] !== undefined && !(typeof c[k] === 'number' && Number.isFinite(c[k]) && c[k] >= lo && c[k] <= hi)) errs.push(`${w}: "${k}" must be a number from ${lo} to ${hi}`);
  }
  if (c.move !== undefined && typeof c.move !== 'boolean') errs.push(`${w}: "move" must be true or false`);
}

function checkVariants(variants, errs) {
  if (!Array.isArray(variants) || variants.length < 1 || variants.length > MAX_VARIANTS) { errs.push(`"variants" must be a list of 1 to ${MAX_VARIANTS} options`); return null; }
  const labels = new Set(), out = [];
  variants.forEach((v, i) => {
    const w = `variant ${i + 1}`;
    if (!isObj(v)) { errs.push(`${w} must be an object {"label", "title", "tune"}`); return; }
    onlyKeys(v, ['label', 'title', 'tune'], w, errs);
    if (typeof v.label !== 'string' || !LABEL_RE.test(v.label)) errs.push(`${w}: "label" must be lowercase letters, digits and dashes (1 to 24 characters), e.g. "slow"`);
    else if (labels.has(v.label)) errs.push(`${w}: the label "${v.label}" is used twice`); else labels.add(v.label);
    const title = typeof v.title === 'string' ? v.title.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim() : '';
    if (!title || title.length > MAX_TITLE) errs.push(`${w}: "title" is what people read under the video (1 to ${MAX_TITLE} characters), e.g. "slow (speed 4)"`);
    checkTune(v.tune === undefined ? {} : v.tune, w, errs);
    out.push({ label: String(v.label), title, tune: isObj(v.tune) ? v.tune : {} });
  });
  return out;
}

// Reads <wt>/.dm-clip.json. null = there is none; { error } = it cannot be used (every problem, readable); { plan, variants } = valid.
// The file is NOT removed here (the caller does, whatever the answer).
function readClipRequest(wt) {
  const f = path.join(wt, CLIP_FILE);
  let st; try { st = fs.lstatSync(f); } catch { return null; }
  if (!st.isFile() || st.size > MAX_BYTES) return { error: `${CLIP_FILE} must be a regular file of at most ${MAX_BYTES / 1024} KB` };
  let j; try { j = JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return { error: `${CLIP_FILE} is not valid JSON` }; }
  const errs = [];
  if (!isObj(j)) return { error: `${CLIP_FILE} must be a JSON object {"plan": {...}, "variants": [...]}` };
  onlyKeys(j, ['plan', 'variants'], CLIP_FILE, errs);
  const plan = checkPlan(j.plan, errs, wt), variants = checkVariants(j.variants, errs);
  if (errs.length || !plan || !variants) return { error: errs.slice(0, 8).join('; ') + (errs.length > 8 ? `; and ${errs.length - 8} more` : '') };
  return { plan: { discipline: plan.discipline, ...(plan.equip ? { equip: plan.equip.slice() } : {}), ...(plan.legion ? { legion: plan.legion.slice() } : {}), clips: plan.clips.map((c) => ({ ...c })) }, variants };
}

// About how long a clip job takes on a team PC, in minutes: each variant is one game run (start-up about a minute, then the clips at the game's pace).
function clipMinutes(plan, variants) {
  const secs = plan.clips.reduce((n, c) => n + (typeof c.seconds === 'number' ? c.seconds : 5), 0);
  return Math.max(2, Math.ceil((variants.length * (60 + 2 * secs)) / 60));
}

// The screen sizes of a shot plan: undefined = none asked, { list } = valid (the sizes, each once), { error } = not usable (the standard size is used instead).
function checkResolutions(v) {
  if (v === undefined) return {};
  if (!Array.isArray(v) || v.length < 1 || v.length > RESOLUTIONS.length || v.some((x) => !RESOLUTIONS.includes(x)) || new Set(v).size !== v.length) {
    return { error: `"resolutions" must be 1 to ${RESOLUTIONS.length} different sizes from ${RESOLUTIONS.join(', ')}` };
  }
  return { list: v.slice() };
}

// The graphics presets of a shot plan: undefined = none asked, { list } = valid (each once, lowest first), { error } = not usable (Ultra alone is used instead).
function checkPresets(v) {
  if (v === undefined) return {};
  if (!Array.isArray(v) || v.length < 1 || v.length > SHOT_PRESETS.length || v.some((x) => !SHOT_PRESETS.includes(x)) || new Set(v).size !== v.length) {
    return { error: `"presets" must be 1 to ${SHOT_PRESETS.length} different presets from ${SHOT_PRESETS.join(', ')}` };
  }
  return { list: SHOT_PRESETS.filter((x) => v.includes(x)) };
}

// A shot's wait in seconds, as the game holds it (main/qa_ui_shots.gd: "wait_ms", 300 when left out, 0 to 5000).
function shotWaitSeconds(s) {
  const ms = typeof s.wait_ms === 'number' && Number.isFinite(s.wait_ms) ? Math.trunc(s.wait_ms) : SHOT_WAIT_MS;
  return Math.min(Math.max(ms, 0), MAX_SHOT_WAIT_MS) / 1000;
}

// A shot plan's shots: every problem with their `setup` and `steps` (the clips' words, checked against the branch's word list the way a clip request's are), joined like a clip request's, or ''.
function checkShotWords(shots, wt) {
  const errs = [];
  let voc;   // read from the branch only when a shot has setup or steps
  shots.forEach((s, i) => {
    if (s.setup === undefined && s.steps === undefined) return;
    const w = `shot ${i + 1}`;
    if (voc === undefined) voc = readVocabulary(wt);
    if (!voc) { errs.push(`${w}: this branch's game has no list of setup and step words (${STEPS_FILE}): merge the latest main first`); return; }
    const secs = shotWaitSeconds(s);
    if (s.setup !== undefined) checkWords(s.setup, 'setup', voc, secs, w, errs, true);
    if (s.steps !== undefined) checkWords(s.steps, 'steps', voc, secs, w, errs, true);
    if (s.thralls !== undefined && Array.isArray(s.setup) && s.setup.some((e) => isObj(e) && e.do === 'thralls')) errs.push(`${w}: the "thralls" key and the "thralls" setup word both raise thralls: use one`);
  });
  return errs.slice(0, 8).join('; ') + (errs.length > 8 ? `; and ${errs.length - 8} more` : '');
}

// The shot plan (.dm-shot.json) the agent leaves for a team PC: a JSON object with a list of shots, at most 32 KB (the game itself holds a plan to 4 shots).
// null = none or unusable; otherwise { plan, notes, before, presets, error }: the plan as it goes to the team PC (a `resolutions` list that is not allowed is left out and
// named in `notes`), whether BEFORE pictures were asked for, and the presets. `before` and `presets` are the runner's, so they are taken out of the plan.
// `error` is '' when the shots' `setup` and `steps` are fine, else every problem in one string (the plan is still returned: the caller says what to fix instead of rendering it).
// `game` is the checkout whose word list counts (the job's worktree) when the plan sits elsewhere (a retake's or a discussion's plan in a scratch folder).
function readShotPlan(wt, game = wt) {
  const f = path.join(wt, '.dm-shot.json');
  try {
    const st = fs.lstatSync(f); if (!st.isFile() || st.size > MAX_BYTES) return null;
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (!(isObj(j) && Array.isArray(j.shots) && j.shots.length >= 1 && j.shots.every(isObj))) return null;
    const notes = [], r = checkResolutions(j.resolutions), pr = checkPresets(j.presets);
    const { before, presets, ...plan } = j;
    if (r.error) { delete plan.resolutions; notes.push(`The screen sizes asked for were not usable (${r.error}), so the standard size was used.`); }
    if (pr.error) notes.push(`The graphics presets asked for were not usable (${pr.error}), so Ultra was used.`);
    if (before !== undefined && typeof before !== 'boolean') notes.push('"before" must be true or false, so there are no BEFORE pictures.');
    return { plan, notes, before: before === true, presets: pr.list || SHOT_PRESETS_DEFAULT.slice(), error: checkShotWords(plan.shots, game) };
  } catch { return null; }
}

module.exports = { CLIP_FILE, STEPS_FILE, MODELS_FILE, MAX_BYTES, MAX_VARIANTS, MAX_CLIPS, MAX_SECONDS, LABEL_RE, CLIP_NAME_RE, CLASSES, RESOLUTIONS, SHOT_PRESETS, classOf, readClipRequest, clipMinutes, readShotPlan, checkResolutions, checkPresets, checkTune };
