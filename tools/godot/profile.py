#!/usr/bin/env python3
"""Function-level GDScript profiler for a headless Godot 4.x run, no editor needed.

Acts as a minimal remote-debugger server (what the editor normally is): it
listens on a free TCP port, launches godot with --remote-debug tcp://127.0.0.1:<port>,
speaks the RemoteDebuggerPeerTCP wire protocol (4-byte LE length + binary Variant,
messages are [name, thread_id, data]), enables the "servers" profiler (same as the
editor's Profiler > Start: profiler:servers [true, [max_functions, save_native]]),
collects servers:function_signature / servers:profile_frame, and prints the top
functions by self time and inclusive time, in ms per profiled frame.
Any debug_enter (script error) is answered with "continue" so the game never stalls.

Usage (from the repo root):
  python3 tools/godot/profile.py [--frames N] [--start-after STR] [--stop-after STR]
        [--json out.json] [--top 40] [--timeout SEC] [--godot PATH] [--project godot]
        -- <script res://...> [script args...]

  python3 tools/godot/profile.py --frames 600 --start-after "FB setup" \
      --stop-after "FB base" --json /tmp/p.json -- \
      res://tests/perf/fight_breakdown.gd --n=30 --thralls=20 --reps=0 --seg=600

Profiling starts when the game's stdout contains --start-after (else immediately on
connect) and ends after --frames profiled frames, on --stop-after, on game exit, or
on --timeout. Note: profiling adds overhead; use the result for relative ranking.
Times are ms per profiled frame (sum over frames / frames); "calls" is calls/frame.
Only the child PID this tool started is ever killed.
"""
import argparse, json, os, select, socket, struct, subprocess, sys, threading, time

# ---- Variant binary (de)serialization (core/io/marshalls.cpp) ----
T_NIL, T_BOOL, T_INT, T_FLOAT, T_STRING = 0, 1, 2, 3, 4
T_STRING_NAME, T_NODE_PATH, T_RID, T_OBJECT, T_CALLABLE, T_SIGNAL = 21, 22, 23, 24, 25, 26
T_DICT, T_ARRAY, T_PBA, T_PI32, T_PI64, T_PF32, T_PF64, T_PSA = 27, 28, 29, 30, 31, 32, 33, 34
T_PV2A, T_PV3A, T_PCA, T_PV4A = 35, 36, 37, 38
F64 = 1 << 16
# type -> (count, kind) ; kind 'r' real (float32/64 per flag), 'i' int32, 'f' float32 always
FIXED = {5: (2, 'r'), 6: (2, 'i'), 7: (4, 'r'), 8: (4, 'i'), 9: (3, 'r'), 10: (3, 'i'),
         11: (6, 'r'), 12: (4, 'r'), 13: (4, 'i'), 14: (4, 'r'), 15: (4, 'r'), 16: (6, 'r'),
         17: (9, 'r'), 18: (12, 'r'), 19: (16, 'r'), 20: (4, 'f')}


class Obj:  # object-as-id
    def __init__(self, i): self.id = i
    def __repr__(self): return "Object(%s)" % self.id


def _dstr(b, o):
    n = struct.unpack_from('<I', b, o)[0]
    s = b[o + 4:o + 4 + n].decode('utf-8', 'replace')
    return s, o + 4 + n + (-n % 4)


def _ctype(b, o, kind):
    if kind == 1: return o + 4
    if kind in (2, 3): return _dstr(b, o)[1]
    return o


def decode(b, o=0):
    h = struct.unpack_from('<I', b, o)[0]; o += 4
    t = h & 0xFF
    if t == T_NIL: return None, o
    if t == T_BOOL: return bool(struct.unpack_from('<I', b, o)[0]), o + 4
    if t == T_INT:
        if h & F64: return struct.unpack_from('<q', b, o)[0], o + 8
        return struct.unpack_from('<i', b, o)[0], o + 4
    if t == T_FLOAT:
        if h & F64: return struct.unpack_from('<d', b, o)[0], o + 8
        return struct.unpack_from('<f', b, o)[0], o + 4
    if t in (T_STRING, T_STRING_NAME): return _dstr(b, o)
    if t in FIXED:
        n, k = FIXED[t]
        if k == 'i': return struct.unpack_from('<%di' % n, b, o), o + 4 * n
        if k == 'f' or not (h & F64): return struct.unpack_from('<%df' % n, b, o), o + 4 * n
        return struct.unpack_from('<%dd' % n, b, o), o + 8 * n
    if t == T_RID: return struct.unpack_from('<Q', b, o)[0], o + 8
    if t == T_OBJECT:
        if h & F64:
            return Obj(struct.unpack_from('<Q', b, o)[0]), o + 8
        raise ValueError("full object not supported")
    if t == T_NODE_PATH:
        n = struct.unpack_from('<I', b, o)[0]
        if n & 0x80000000:
            nc = n & 0x7FFFFFFF; sc = struct.unpack_from('<I', b, o + 4)[0]; o += 12
            parts = []
            for _ in range(nc + sc):
                s, o = _dstr(b, o); parts.append(s)
            return ':'.join(parts), o
        return _dstr(b, o)
    if t == T_ARRAY:
        o = _ctype(b, o, (h >> 16) & 3)
        n = struct.unpack_from('<I', b, o)[0] & 0x7FFFFFFF; o += 4
        out = []
        for _ in range(n):
            v, o = decode(b, o); out.append(v)
        return out, o
    if t == T_DICT:
        o = _ctype(b, o, (h >> 16) & 3); o = _ctype(b, o, (h >> 18) & 3)
        n = struct.unpack_from('<I', b, o)[0] & 0x7FFFFFFF; o += 4
        out = {}
        for _ in range(n):
            k, o = decode(b, o); v, o = decode(b, o)
            out[k if isinstance(k, (str, int, float, bool, type(None))) else repr(k)] = v
        return out, o
    if t in (T_PBA, T_PI32, T_PI64, T_PF32, T_PF64, T_PCA, T_PV2A, T_PV3A, T_PV4A, T_PSA):
        n = struct.unpack_from('<I', b, o)[0]; o += 4
        if t == T_PBA: return bytes(b[o:o + n]), o + n + (-n % 4)
        if t == T_PSA:
            out = []
            for _ in range(n):
                s, o = _dstr(b, o); out.append(s)
            return out, o
        fmt, sz, per = {T_PI32: ('i', 4, 1), T_PI64: ('q', 8, 1), T_PF32: ('f', 4, 1), T_PF64: ('d', 8, 1),
                        T_PCA: ('f', 4, 4)}.get(t, (None,) * 3)
        if fmt is None:
            r = 8 if h & F64 else 4
            per = {T_PV2A: 2, T_PV3A: 3, T_PV4A: 4}[t]; fmt = 'd' if r == 8 else 'f'; sz = r
        cnt = n * per
        return list(struct.unpack_from('<%d%s' % (cnt, fmt), b, o)), o + cnt * sz
    raise ValueError("unsupported variant type %d" % t)


def _dstr_enc(s):
    d = s.encode('utf-8')
    return struct.pack('<I', len(d)) + d + b'\0' * (-len(d) % 4)


def encode(v):
    if v is None: return struct.pack('<I', T_NIL)
    if isinstance(v, bool): return struct.pack('<II', T_BOOL, int(v))
    if isinstance(v, int):
        if -2**31 <= v < 2**31: return struct.pack('<Ii', T_INT, v)
        return struct.pack('<Iq', T_INT | F64, v)
    if isinstance(v, float): return struct.pack('<Id', T_FLOAT | F64, v)
    if isinstance(v, str): return struct.pack('<I', T_STRING) + _dstr_enc(v)
    if isinstance(v, (list, tuple)):
        return struct.pack('<II', T_ARRAY, len(v)) + b''.join(encode(x) for x in v)
    raise ValueError("cannot encode %r" % (v,))


def packet(msg):
    p = encode(msg)
    return struct.pack('<I', len(p)) + p


class Peer:
    def __init__(self, sock):
        self.s = sock; self.buf = bytearray(); self.closed = False
        sock.setblocking(False)

    def send(self, name, thread, data):
        try:
            self.s.setblocking(True)
            self.s.sendall(packet([name, thread, data]))
        except OSError:
            self.closed = True
        finally:
            try: self.s.setblocking(False)
            except OSError: pass

    def poll(self, timeout):
        """Return list of decoded messages (may be empty)."""
        msgs = []
        r, _, _ = select.select([self.s], [], [], timeout)
        if r:
            try:
                d = self.s.recv(1 << 20)
            except BlockingIOError:
                d = None
            except OSError:
                d = b''
            if d == b'': self.closed = True
            elif d: self.buf += d
        while len(self.buf) >= 4:
            n = struct.unpack_from('<I', self.buf, 0)[0]
            if len(self.buf) < 4 + n: break
            raw = bytes(self.buf[4:4 + n]); del self.buf[:4 + n]
            try:
                m, _ = decode(raw)
                if isinstance(m, list) and len(m) == 3: msgs.append(m)
            except Exception as e:  # keep going on odd packets
                print("[profile] decode error: %s" % e, file=sys.stderr)
        return msgs


def parse_frame(d):
    """servers:profile_frame data -> dict."""
    f = dict(frame=d[0], frame_time=d[1], process=d[2], physics=d[3], physics_frame=d[4], script=d[5])
    ns = d[6]; i = 7; servers = {}
    for _ in range(ns):
        name = d[i]; cnt = d[i + 1]; i += 2
        servers[name] = {d[i + j]: d[i + j + 1] for j in range(0, cnt, 2)}; i += cnt
    nf = d[i]; i += 1
    funcs = [tuple(d[i + j:i + j + 5]) for j in range(0, nf, 5)]
    f['servers'] = servers; f['funcs'] = funcs
    return f


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--frames', type=int, default=600, help='profiled frames to collect (default 600)')
    ap.add_argument('--start-after', help='start profiling after game stdout contains this')
    ap.add_argument('--stop-after', help='stop profiling after game stdout contains this')
    ap.add_argument('--json', help='write raw aggregate JSON here')
    ap.add_argument('--top', type=int, default=40)
    ap.add_argument('--timeout', type=float, default=900, help='overall seconds before killing the game')
    ap.add_argument('--godot', default=os.environ.get('GODOT', '/home/ubuntu/tools/godot/godot'))
    ap.add_argument('--project', default='godot')
    ap.add_argument('--fixed-fps', type=int, default=60)
    ap.add_argument('--max-functions', type=int, default=1024)
    ap.add_argument('--native', action='store_true', help='also record native calls')
    ap.add_argument('--quiet', action='store_true', help='do not echo game stdout')
    ap.add_argument('rest', nargs=argparse.REMAINDER, help='-- <script> [args]')
    a = ap.parse_args()
    rest = a.rest[1:] if a.rest and a.rest[0] == '--' else a.rest
    if not rest: ap.error('need -- <script> [args]')

    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', 0)); srv.listen(1)
    port = srv.getsockname()[1]
    cmd = ['nice', '-n', '10', a.godot, '--headless', '--fixed-fps', str(a.fixed_fps),
           '--remote-debug', 'tcp://127.0.0.1:%d' % port, '--path', a.project,
           '--script', rest[0], '--'] + rest[1:]
    print('[profile] ' + ' '.join(cmd), file=sys.stderr)
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                             errors='replace')
    state = dict(start=a.start_after is None, stop=False, text='')
    lock = threading.Lock()

    def reader():
        for line in child.stdout:
            if not a.quiet: sys.stdout.write(line); sys.stdout.flush()
            with lock:
                if a.start_after and not state['start'] and a.start_after in line: state['start'] = True
                if a.stop_after and a.stop_after in line and (state['start'] or not a.start_after):
                    state['stop'] = True
    threading.Thread(target=reader, daemon=True).start()

    sigs = {}      # id -> name
    agg = {}       # name -> [calls, self, total, internal, frames_present]
    fr = dict(n=0, frame_time=0.0, process=0.0, physics=0.0, physics_frame=0.0, script=0.0)
    servers_agg = {}
    main_thread = [None]
    profiling = False
    t0 = time.time()
    peer = None
    try:
        srv.settimeout(1.0)
        while peer is None:
            if child.poll() is not None: raise SystemExit('godot exited before connecting (rc=%s)' % child.returncode)
            if time.time() - t0 > a.timeout: raise SystemExit('timeout waiting for connect')
            try:
                c, _ = srv.accept(); peer = Peer(c)
            except socket.timeout:
                pass
        print('[profile] game connected', file=sys.stderr)
        stopping = False
        while not peer.closed and child.poll() is None:
            if time.time() - t0 > a.timeout:
                print('[profile] timeout', file=sys.stderr); break
            for name, thread, data in peer.poll(0.05):
                if main_thread[0] is None and name.startswith('performance:'): main_thread[0] = thread
                if name == 'debug_enter':
                    # never break: continue on the thread that hit the error
                    print('[profile] debug_enter (%s); sending continue' % (data[1] if len(data) > 1 else ''),
                          file=sys.stderr)
                    peer.send('continue', thread, [])
                elif name == 'servers:function_signature':
                    sigs[data[1]] = data[0]
                elif name == 'servers:profile_frame' and profiling and not stopping:
                    f = parse_frame(data)
                    fr['n'] += 1
                    for k in ('frame_time', 'process', 'physics', 'physics_frame', 'script'): fr[k] += f[k]
                    for sid, calls, st, tt, it in f['funcs']:
                        e = agg.setdefault(sid, [0, 0.0, 0.0, 0.0, 0])
                        e[0] += calls; e[1] += st; e[2] += tt; e[3] += it; e[4] += 1
                    for sn, fns in f['servers'].items():
                        for fn, t in fns.items():
                            servers_agg[sn + '/' + fn] = servers_agg.get(sn + '/' + fn, 0.0) + t
                    if fr['n'] >= a.frames: stopping = True
                elif name == 'error':
                    pass
            with lock: go, stop = state['start'], state['stop']
            if go and not profiling and not stopping:
                print('[profile] starting profiler', file=sys.stderr)
                peer.send('profiler:servers', main_thread[0] or 1, [True, [a.max_functions, bool(a.native)]])
                profiling = True
            if stop and profiling: stopping = True
            if stopping: break
        if profiling and not peer.closed:
            peer.send('profiler:servers', main_thread[0] or 1, [False])
    finally:
        if child.poll() is None:
            child.terminate()
            try: child.wait(5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
        srv.close()

    n = fr['n']
    if n == 0:
        print('[profile] no frames collected', file=sys.stderr); return 1
    ms = 1000.0 / n
    rows = [(sigs.get(sid, '#%d' % sid), e[0] / n, e[1] * ms, e[2] * ms, e[3] * ms, e[4] / n) for sid, e in agg.items()]
    print('\n=== GDScript profile: %d frames ===' % n)
    print('per frame (ms): frame=%.3f process=%.3f physics=%.3f physics_frame=%.3f script=%.3f' % (
        fr['frame_time'] * ms, fr['process'] * ms, fr['physics'] * ms, fr['physics_frame'] * ms, fr['script'] * ms))
    hdr = '%-3s %-84s %9s %9s %9s' % ('#', 'function', 'self ms/f', 'incl ms/f', 'calls/f')
    for title, key in (('TOP %d BY SELF TIME' % a.top, 3), ('TOP %d BY INCLUSIVE TIME' % a.top, 4)):
        print('\n--- %s ---' % title); print(hdr)
        for i, r in enumerate(sorted(rows, key=lambda r: -(r[2] if key == 3 else r[3]))[:a.top], 1):
            print('%-3d %-84s %9.4f %9.4f %9.2f' % (i, r[0][-84:], r[2], r[3], r[1]))
    sv = sorted(servers_agg.items(), key=lambda kv: -kv[1])[:10]
    if sv:
        print('\n--- server functions (ms/frame) ---')
        for k, v in sv: print('%-60s %9.4f' % (k, v * ms))
    if a.json:
        out = dict(frames=n, ms_per_frame=dict(frame=fr['frame_time'] * ms, process=fr['process'] * ms,
                   physics=fr['physics'] * ms, physics_frame=fr['physics_frame'] * ms, script=fr['script'] * ms),
                   functions=[dict(name=r[0], calls_per_frame=r[1], self_ms=r[2], incl_ms=r[3], internal_ms=r[4],
                                   frames_present_ratio=r[5]) for r in sorted(rows, key=lambda r: -r[2])],
                   servers_ms={k: v * ms for k, v in servers_agg.items()})
        with open(a.json, 'w') as f: json.dump(out, f, indent=1)
        print('[profile] wrote %s' % a.json, file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
