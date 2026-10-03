// Summarise an ab-profile.cjs JSON: non-GL JS ms/frame (shader-compile time subtracted), GC, updateMatrixWorld, top self/inclusive functions.
//   node tools/qa/ab-summary.cjs result.json [more.json ...]
const GL = /^(getShaderInfoLog|getProgramInfoLog|shaderSource|linkProgram|compileShader|getShaderParameter|getProgramParameter|getUniformLocation|getActiveUniform|getActiveAttrib|getAttribLocation|useProgram|createProgram)\b/;
for (const file of process.argv.slice(2)) {
  const r = require(require('node:path').resolve(file));
  let gl = 0;
  for (const [k, v] of r.topFn) if (GL.test(k)) gl += v;
  const frames = r.frames.frames, busy = r.busyMs, js = busy - gl;
  const per = (ms) => (ms / frames).toFixed(3);
  const pick = (re, list = r.topFn) => list.filter(([k]) => re.test(k)).reduce((a, [, v]) => a + v, 0);
  const nt = r.census0.thralls;
  console.log(`== ${file}: ${r.area} enemies ${r.census0.enemies} thralls ${nt} corpses ${r.census0.corpses}`);
  console.log(`nonGL JS ${per(js)} ms/frame (busy ${per(busy)}, GL compile ${per(gl)})  per-thrall ${nt ? (js / frames / nt).toFixed(3) : '-'} ms  heap growth ${(r.metricsDelta.JSHeapUsedSize / 1e6).toFixed(1)} MB/${frames} fr`);
  if (r.windows) {
    const th = r.windows.map((w) => w.threadMs / w.frames).sort((a, b) => a - b);
    console.log(`WINDOWS thread CPU ms/frame: median ${th[Math.floor(th.length / 2)].toFixed(3)} min ${th[0].toFixed(3)} all [${th.map((x) => x.toFixed(2)).join(', ')}]  per-thrall(median) ${nt ? (th[Math.floor(th.length / 2)] / nt).toFixed(3) : '-'}`);
  }
  console.log(`CPU thread time ${(r.metricsDelta.ThreadTime * 1000 / frames).toFixed(3)} ms/frame   allocated ${r.allocBytes ? (r.allocBytes / frames / 1024).toFixed(1) : '?'} KB/frame`);
  console.log(`GC self ${per(pick(/garbage collector/i))} (${(pick(/garbage collector/i) / js * 100).toFixed(1)}% of nonGL)  updateMatrixWorld self ${per(pick(/^updateMatrixWorld/))} (${(pick(/^updateMatrixWorld/) / js * 100).toFixed(1)}%)  (program) ${per(pick(/^\(program\)/))}`);
  if (r.topIncl) {
    console.log('inclusive ms/frame:');
    for (const [k, v] of r.topIncl.filter(([k]) => /src\/|updateMatrixWorld|garbage/.test(k)).slice(0, 18)) console.log('  ', per(v), k.replace(/node_modules\/\.vite\/deps\/chunk-\w+\.js\?v=\w+/, 'three'));
  }
  if (r.allocTop) { console.log('top allocators (KB/frame):'); for (const [k, v] of r.allocTop.slice(0, 10)) console.log('  ', (v / frames / 1024).toFixed(1), k); }
  console.log('self:');
  for (const [k, v] of r.topFn.filter(([k]) => !GL.test(k)).slice(0, 12)) console.log('  ', per(v), k.replace(/node_modules\/\.vite\/deps\/chunk-\w+\.js\?v=\w+/, 'three'));
}
