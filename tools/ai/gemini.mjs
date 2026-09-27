/**
 * gemini.mjs — Gemini image generation / editing for 2D assets and 3D concept
 * sheets. Every output gets a manifest entry (prompt, model, references,
 * output hash) in art-manifest/images.json.
 *
 * Usage:
 *   node tools/ai/gemini.mjs <jobs.json> [jobId ...]      run jobs (skips ones already generated)
 *   node tools/ai/gemini.mjs <jobs.json> --force <jobId>  regenerate one job
 *
 * jobs.json: [{ id, prompt, out, refs?: [path], crop?: {left,top,width,height} applied to refs[0],
 *              aspect?: "1:1", size?: "1K", model?, post?: { resize?: [w,h], format?: "png"|"webp",
 *              removeBg?: "#rrggbb", lumaAlpha?: true, floor?: 0-255, mask?: "circle"|"cone" } }]
 *   lumaAlpha turns white-on-black VFX art into a white sprite with brightness as alpha
 *   (tinted in code); mask clips it to a soft circle or a 70° fan (apex bottom centre).
 */
import sharp from 'sharp';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { ensureDir, loadKey, MANIFEST_DIR, readJson, redact, ROOT, sha256, sleep, writeJson } from './common.mjs';

const DEFAULT_MODEL = 'gemini-3.1-flash-image';
const API = 'https://generativelanguage.googleapis.com/v1beta/models';
const MANIFEST = join(MANIFEST_DIR, 'images.json');

async function refPart(path, crop) {
  let img = sharp(join(ROOT, path));
  if (crop) img = img.extract(crop);
  const buf = await img.png().toBuffer();
  return { inline_data: { mime_type: 'image/png', data: buf.toString('base64') } };
}

async function generate(job, key) {
  const parts = [{ text: job.prompt }];
  for (const [i, ref] of (job.refs ?? []).entries()) {
    parts.push(await refPart(ref, i === 0 ? job.crop : undefined));
  }
  const body = {
    contents: [{ role: 'user', parts }],
    generationConfig: {
      responseModalities: ['IMAGE'],
      imageConfig: { aspectRatio: job.aspect ?? '1:1', ...(job.size ? { imageSize: job.size } : {}) },
    },
  };
  const model = job.model ?? DEFAULT_MODEL;
  for (let attempt = 1; attempt <= 4; attempt++) {
    const res = await fetch(`${API}/${model}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify(body),
    });
    const json = await res.json().catch(() => ({}));
    if (res.status === 429 || res.status >= 500) {
      console.warn(`  ${job.id}: HTTP ${res.status}, retry ${attempt}`);
      await sleep(4000 * attempt);
      continue;
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${redact(JSON.stringify(json.error ?? json)).slice(0, 400)}`);
    const out = json.candidates?.[0]?.content?.parts?.find((p) => p.inlineData || p.inline_data);
    const data = out?.inlineData?.data ?? out?.inline_data?.data;
    if (!data) {
      const reason = json.candidates?.[0]?.finishReason ?? json.promptFeedback?.blockReason ?? 'no image returned';
      throw new Error(`no image: ${reason}`);
    }
    return { buf: Buffer.from(data, 'base64'), model };
  }
  throw new Error('gave up after retries');
}

/** Flood-remove a flat background colour (for icons generated on a solid key colour). */
async function removeBackground(buf, hex, tolerance = 42) {
  const [r0, g0, b0] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const { data, info } = await sharp(buf).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let i = 0; i < data.length; i += 4) {
    const d = Math.abs(data[i] - r0) + Math.abs(data[i + 1] - g0) + Math.abs(data[i + 2] - b0);
    if (d < tolerance) data[i + 3] = 0;
    else if (d < tolerance * 2) data[i + 3] = Math.round((255 * (d - tolerance)) / tolerance);
  }
  return sharp(data, { raw: info }).png().toBuffer();
}

/**
 * Soft shape masks for tintable VFX sprites (0..1 per pixel). `circle` fades to
 * nothing at the rim; `cone` is a 70° fan with its apex at the bottom centre —
 * the same frame as fxTextures.cone(), so decals can use `anchor: 1`.
 */
const MASKS = {
  circle: (x, y) => {
    const d = Math.hypot(x - 0.5, y - 0.5) / 0.5;
    return d >= 1 ? 0 : d <= 0.78 ? 1 : 1 - (d - 0.78) / 0.22;
  },
  cone: (x, y) => {
    const dx = x - 0.5;
    const dy = 1 - y;
    const d = Math.hypot(dx, dy);
    if (d <= 0 || d >= 1) return 0;
    const off = Math.abs(Math.atan2(dx, dy)) / ((35 * Math.PI) / 180);
    const side = off >= 1 ? 0 : off <= 0.75 ? 1 : 1 - (off - 0.75) / 0.25;
    const rim = d <= 0.85 ? 1 : 1 - (d - 0.85) / 0.15;
    return side * rim;
  },
};

/**
 * White-on-black VFX art → white sprite whose alpha is its brightness, so the
 * game can tint it per spell (SPELL_FX). `floor` crushes the near-black noise
 * Gemini leaves in "pure black" backgrounds; `mask` clips to a soft shape.
 */
async function lumaAlpha(buf, job) {
  const { data, info } = await sharp(buf).greyscale().raw().toBuffer({ resolveWithObject: true });
  const floor = job.post.floor ?? 18;
  const mask = job.post.mask ? MASKS[job.post.mask] : null;
  const out = Buffer.alloc(info.width * info.height * 4);
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const i = y * info.width + x;
      let a = Math.max(0, (data[i * info.channels] - floor) / (255 - floor));
      if (mask) a *= mask((x + 0.5) / info.width, (y + 0.5) / info.height);
      out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = 255;
      out[i * 4 + 3] = Math.round(Math.min(1, a) * 255);
    }
  }
  return sharp(out, { raw: { width: info.width, height: info.height, channels: 4 } }).png().toBuffer();
}

async function post(buf, job) {
  let out = buf;
  if (job.post?.removeBg) out = await removeBackground(out, job.post.removeBg);
  if (job.post?.lumaAlpha) out = await lumaAlpha(out, job);
  let img = sharp(out);
  if (job.post?.resize) img = img.resize(job.post.resize[0], job.post.resize[1], { fit: 'cover' });
  const fmt = job.post?.format ?? (job.out.endsWith('.webp') ? 'webp' : 'png');
  return fmt === 'webp' ? img.webp({ quality: 88 }).toBuffer() : img.png({ compressionLevel: 9 }).toBuffer();
}

async function main() {
  const [jobsFile, ...rest] = process.argv.slice(2);
  if (!jobsFile) {
    console.error('usage: node tools/ai/gemini.mjs <jobs.json> [--force] [jobId ...]');
    process.exit(1);
  }
  const force = rest.includes('--force');
  const only = rest.filter((a) => a !== '--force');
  const jobs = readJson(join(ROOT, jobsFile));
  const manifest = readJson(MANIFEST, {});
  const key = loadKey('GEMINI_API_KEY');

  for (const job of jobs) {
    if (only.length && !only.includes(job.id)) continue;
    const outPath = join(ROOT, job.out);
    if (existsSync(outPath) && !force) {
      console.log(`skip ${job.id} (exists)`);
      continue;
    }
    process.stdout.write(`gen  ${job.id} … `);
    try {
      const { buf, model } = await generate(job, key);
      const rawPath = join(ROOT, 'art-src', 'gemini', `${job.id}.png`);
      ensureDir(dirname(rawPath));
      writeFileSync(rawPath, buf);
      const final = await post(buf, job);
      ensureDir(dirname(outPath));
      writeFileSync(outPath, final);
      manifest[job.id] = {
        generator: 'gemini',
        model,
        prompt: job.prompt,
        refs: job.refs ?? [],
        crop: job.crop ?? null,
        aspect: job.aspect ?? '1:1',
        post: job.post ?? null,
        out: relative(ROOT, outPath).replace(/\\/g, '/'),
        rawHash: sha256(buf),
        outHash: sha256(final),
        generatedAt: new Date().toISOString(),
      };
      writeJson(MANIFEST, manifest);
      console.log(`ok (${(final.length / 1024).toFixed(0)}KB)`);
    } catch (err) {
      console.log(`FAILED: ${redact(err.message)}`);
    }
  }
}

main().catch((e) => {
  console.error(redact(e.stack ?? e));
  process.exit(1);
});
