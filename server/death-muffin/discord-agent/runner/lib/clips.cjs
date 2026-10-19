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
//
// The shot plan (.dm-shot.json) may carry `resolutions`: the screen sizes a team PC renders every shot at (default: the one standard size). The list is checked here.
const fs = require('fs');
const path = require('path');

const CLIP_FILE = '.dm-clip.json';
const MAX_BYTES = 32 * 1024;
const MAX_VARIANTS = 4, MAX_CLIPS = 4, MAX_SECONDS = 8, MAX_ENEMIES = 12, MAX_TITLE = 60, MAX_EQUIP = 12;
const MAX_TUNE_DEPTH = 6, MAX_TUNE_LEAVES = 64, MAX_TUNE_TEXT = 100;
const LABEL_RE = /^[a-z0-9][a-z0-9-]{0,23}$/;           // a variant's label: the first half of the uploaded file's name
const CLIP_NAME_RE = /^[a-z0-9][a-z0-9-]{0,29}$/;       // no underscore: `<label>_<clip>` splits at the first one
const AREA_RE = /^[a-z0-9_-]{1,40}$/, CAST_RE = /^[a-z0-9_]{1,60}$/, ITEM_RE = /^[a-z0-9_]{1,60}$/;
const CAMERAS = ['follow', 'wide', 'turntable'];
// The screen sizes a shot plan may ask for (a team PC renders each shot at every size listed; with none the game's standard 1600x900 is used).
const RESOLUTIONS = ['1920x1080', '2560x1440', '3840x2160', '3440x1440'];
const TUNE_KEY_RE = /^[A-Za-z0-9_][A-Za-z0-9_./-]{0,79}$/;
const BAD_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
// Playable disciplines by name -> class index (client/data/combat/disciplines.json by_index; the shot plan and the clip plan name one the same way).
const CLASSES = { ossuary: 1, gravecaller: 2, mourner: 3, rotweaver: 4, reaper: 11 };
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

function checkPlan(plan, errs) {
  if (!isObj(plan)) { errs.push('"plan" must be an object {"discipline": "reaper", "clips": [...]}'); return null; }
  onlyKeys(plan, ['discipline', 'equip', 'clips'], '"plan"', errs);
  if (!classOf(plan.discipline)) errs.push(`"plan.discipline" must be one of ${Object.keys(CLASSES).join(', ')}`);
  if (plan.equip !== undefined) checkEquip(plan.equip, '"plan"', errs);
  if (!Array.isArray(plan.clips) || plan.clips.length < 1 || plan.clips.length > MAX_CLIPS) { errs.push(`"plan.clips" must be a list of 1 to ${MAX_CLIPS} clips`); return null; }
  const names = new Set();
  plan.clips.forEach((c, i) => {
    const w = `clip ${i + 1}`;
    if (!isObj(c)) { errs.push(`${w} must be an object`); return; }
    onlyKeys(c, ['name', 'area', 'cast', 'at', 'enemies', 'seconds', 'camera', 'equip'], w, errs);
    if (typeof c.name !== 'string' || !CLIP_NAME_RE.test(c.name)) errs.push(`${w}: "name" must be lowercase letters, digits and dashes (1 to 30 characters, no underscore)`);
    else if (names.has(c.name)) errs.push(`${w}: the name "${c.name}" is used twice`); else names.add(c.name);
    if (c.area !== undefined && (typeof c.area !== 'string' || !AREA_RE.test(c.area))) errs.push(`${w}: "area" must be an area id such as graves (the Hollow Graves when left out)`);
    // a turntable clip casts nothing, so it needs no rite
    if (c.cast === undefined && c.camera === 'turntable') { /* a model preview */ }
    else if (typeof c.cast !== 'string' || !CAST_RE.test(c.cast)) errs.push(`${w}: "cast" must be a rite id such as haunting_wraith (only a "turntable" clip may leave it out)`);
    if (c.at !== undefined && c.at !== 'pack' && c.at !== 'ahead') errs.push(`${w}: "at" must be "pack" or "ahead"`);
    if (c.camera !== undefined && !CAMERAS.includes(c.camera)) errs.push(`${w}: "camera" must be "follow", "wide" or "turntable"`);
    if (c.equip !== undefined) checkEquip(c.equip, w, errs);
    if (c.enemies !== undefined && !(Number.isInteger(c.enemies) && c.enemies >= 0 && c.enemies <= MAX_ENEMIES)) errs.push(`${w}: "enemies" must be a whole number from 0 to ${MAX_ENEMIES}`);
    if (c.seconds !== undefined && !(typeof c.seconds === 'number' && c.seconds > 0 && c.seconds <= MAX_SECONDS)) errs.push(`${w}: "seconds" must be a number above 0 and at most ${MAX_SECONDS} (5 when left out)`);
  });
  return plan;
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
  const plan = checkPlan(j.plan, errs), variants = checkVariants(j.variants, errs);
  if (errs.length || !plan || !variants) return { error: errs.slice(0, 8).join('; ') + (errs.length > 8 ? `; and ${errs.length - 8} more` : '') };
  return { plan: { discipline: plan.discipline, ...(plan.equip ? { equip: plan.equip.slice() } : {}), clips: plan.clips.map((c) => ({ ...c })) }, variants };
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

// The shot plan (.dm-shot.json) the agent leaves for a team PC: a JSON object with a list of shots, at most 32 KB (the game itself holds a plan to 4 shots).
// null = none or unusable; otherwise { plan, notes }: the plan as it goes to the team PC (a `resolutions` list that is not allowed is left out and named in `notes`).
function readShotPlan(wt) {
  const f = path.join(wt, '.dm-shot.json');
  try {
    const st = fs.lstatSync(f); if (!st.isFile() || st.size > MAX_BYTES) return null;
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (!(isObj(j) && Array.isArray(j.shots) && j.shots.length >= 1 && j.shots.every(isObj))) return null;
    const notes = [], r = checkResolutions(j.resolutions);
    const plan = { ...j };
    if (r.error) { delete plan.resolutions; notes.push(`The screen sizes asked for were not usable (${r.error}), so the standard size was used.`); }
    return { plan, notes };
  } catch { return null; }
}

module.exports = { CLIP_FILE, MAX_BYTES, MAX_VARIANTS, MAX_CLIPS, MAX_SECONDS, LABEL_RE, CLIP_NAME_RE, CLASSES, RESOLUTIONS, classOf, readClipRequest, clipMinutes, readShotPlan, checkResolutions, checkTune };
