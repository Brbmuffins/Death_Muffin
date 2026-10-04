/** Bit-exact JSON for the Godot sim data (see below). No side effects: safe to import from exporters. */
/**
 * JSON with bit-exact doubles. Godot's JSON parser (and GDScript's literal parser) is NOT correctly rounded for numbers with more than
 * 12 significant digits (13% of random 17-digit doubles come out one ulp off), and the sim replays must be bit-identical to the TS. So any
 * double that is not safely short is written as the string "d:<16 hex digits of its IEEE-754 bits>"; godot/sim/sim_exact.gd (DmSimExact.decode)
 * turns those strings back into floats after JSON.parse_string.
 */
const _dv = new DataView(new ArrayBuffer(8));
export function exactStringify(obj: unknown): string {
  return JSON.stringify(obj, (_k, v) => {
    if (typeof v !== 'number' || !Number.isFinite(v)) return v;
    const s = String(Math.abs(v));
    const mant = s.includes('e') ? s.split('e')[0] : s;
    const digits = mant.replace('.', '').replace(/^0+/, '').length;
    const bigInt = Number.isInteger(v) && Math.abs(v) >= 1e12;
    if (digits <= 12 && !bigInt && !s.includes('e') && !Object.is(v, -0)) return v;
    _dv.setFloat64(0, v);
    return 'd:' + _dv.getUint32(0).toString(16).padStart(8, '0') + _dv.getUint32(4).toString(16).padStart(8, '0');
  });
}


/** Inverse of exactStringify (the TS fixture tools read world.json too). */
export function exactParse(text: string): unknown {
  return JSON.parse(text, (_k, v) => {
    if (typeof v === 'string' && v.startsWith('d:') && v.length === 18) {
      _dv.setUint32(0, parseInt(v.slice(2, 10), 16));
      _dv.setUint32(4, parseInt(v.slice(10, 18), 16));
      return _dv.getFloat64(0);
    }
    return v;
  });
}
