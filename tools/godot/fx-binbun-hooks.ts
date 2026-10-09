// Shader rewrites shared by fx-binbun-rebuild.ts and fx-binbun-unlit.ts.

/**
 * Lit (non-`unshaded`) spatial effect shaders become unshaded with the web port's output, `ALBEDO * 0.25 + EMISSION`
 * (archive/legacy-web:src/graphics/binbun/shaders.ts: "lit = ALBEDO·0.25 + EMISSION"). Lit, each overlapping smoke/cloud layer ran the Compatibility
 * renderer's whole light loop (8 omni lights + the moon) per pixel: Miasma's cloud alone cost about as much as the rest of the frame,
 * and at night it rendered as faint smudges. Idempotent (a shader already unshaded is left alone).
 */
export function unlitHook(src: string): string {
  if (!/shader_type\s+spatial/.test(src)) return src;
  const rm = src.match(/render_mode\s+([^;]*);/);
  if (rm && /\bunshaded\b/.test(rm[1])) return src;
  const at = src.search(/void\s+fragment\s*\(\s*\)/);
  if (at < 0) return src;
  const open = src.indexOf('{', at);
  let depth = 0;
  let close = -1;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) {
      close = i;
      break;
    }
  }
  if (close < 0) return src;
  const hook = '\n\t// dm: the web port\'s lit output, unshaded (tools/godot/fx-binbun-hooks.ts unlitHook)\n\tALBEDO = ALBEDO * 0.25 + EMISSION;\n';
  let out = src.slice(0, close) + hook + src.slice(close);
  if (rm) out = out.replace(rm[0], `render_mode ${rm[1].trim() ? rm[1].trim() + ', ' : ''}unshaded;`);
  else out = out.replace(/(shader_type\s+spatial\s*;)/, '$1\nrender_mode unshaded;');
  return out;
}
