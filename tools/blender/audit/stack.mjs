// node stack.mjs <out.webp> <top.png> <bottom.png> [width=1000]  — stacks the textured and wireframe renders into one small WebP
import sharp from 'sharp';
const [out, a, b, w = '1000'] = process.argv.slice(2);
const W = +w; const ia = await sharp(a).resize(W).toBuffer(); const ib = await sharp(b).resize(W).toBuffer();
const ma = await sharp(ia).metadata(), mb = await sharp(ib).metadata();
await sharp({ create: { width: W, height: ma.height + mb.height, channels: 3, background: '#1a1620' } }).composite([{ input: ia, top: 0, left: 0 }, { input: ib, top: ma.height, left: 0 }]).webp({ quality: 80 }).toFile(out);
