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
 *              removeBg?: "#rrggbb" } }]
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

async function post(buf, job) {
  let out = buf;
  if (job.post?.removeBg) out = await removeBackground(out, job.post.removeBg);
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
