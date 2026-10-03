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
  console.log(`GC self ${per(pick(/garbage collector/i))} (${(pick(/garbage collector/i) / js * 100).toFixed(1)}% of nonGL)  updateMatrixWorld self ${per(pick(/^updateMatrixWorld/))} (${(pick(/^updateMatrixWorld/) / js * 100).toFixed(1)}%)  (program) ${per(pick(/^\(program\)/))}`);
  if (r.topIncl) {
    console.log('inclusive ms/frame:');
    for (const [k, v] of r.topIncl.filter(([k]) => /src\/|updateMatrixWorld|garbage/.test(k)).slice(0, 18)) console.log('  ', per(v), k.replace(/node_modules\/\.vite\/deps\/chunk-\w+\.js\?v=\w+/, 'three'));
  }
  console.log('self:');
  for (const [k, v] of r.topFn.filter(([k]) => !GL.test(k)).slice(0, 12)) console.log('  ', per(v), k.replace(/node_modules\/\.vite\/deps\/chunk-\w+\.js\?v=\w+/, 'three'));
}
