using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DeathMuffinLauncher;

namespace DeathMuffinLauncher.Tests
{
    static class T
    {
        static int pass, fail;
        public static void Ok(bool c, string name) { if (c) pass++; else { fail++; Console.WriteLine("FAIL: " + name); } }
        public static void Eq<X>(X a, X b, string name) { Ok(Equals(a, b), name + " (got " + a + ", want " + b + ")"); }
        public static int Done() { Console.WriteLine(pass + " passed, " + fail + " failed"); return fail == 0 ? 0 : 1; }
    }

    // A small file server with Range support and fault injection.
    sealed class TestServer : IDisposable
    {
        public readonly HttpListener L = new HttpListener();
        public readonly string Base;
        public readonly Dictionary<string, byte[]> Files = new Dictionary<string, byte[]>();
        public readonly List<string> RangeHeaders = new List<string>();
        public readonly Dictionary<string, int> Hits = new Dictionary<string, int>();
        /// <summary>path -> bytes to send before dropping the connection on the FIRST request.</summary>
        public readonly Dictionary<string, int> DropFirstAfter = new Dictionary<string, int>();
        /// <summary>path -> serve flipped bytes on the first N requests.</summary>
        public readonly Dictionary<string, int> CorruptFirst = new Dictionary<string, int>();
        public bool AlwaysCorrupt;
        public bool IgnoreRange;

        public TestServer()
        {
            int port;
            using (var s = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0)) { s.Start(); port = ((IPEndPoint)s.LocalEndpoint).Port; s.Stop(); }
            Base = "http://127.0.0.1:" + port + "/client/";
            L.Prefixes.Add(Base);
            L.Start();
            Task.Run(Loop);
        }

        async Task Loop()
        {
            while (L.IsListening)
            {
                HttpListenerContext c;
                try { c = await L.GetContextAsync(); } catch (Exception) { return; }
                var ignored = Task.Run(() => Handle(c));
            }
        }

        void Handle(HttpListenerContext c)
        {
            string path = c.Request.Url.AbsolutePath.Substring("/client/".Length);
            try
            {
                byte[] data;
                lock (Hits) { Hits[path] = Hits.ContainsKey(path) ? Hits[path] + 1 : 1; }
                if (!Files.TryGetValue(path, out data)) { c.Response.StatusCode = 404; c.Response.Close(); return; }
                int hit = Hits[path];
                string range = c.Request.Headers["Range"];
                if (range != null) lock (RangeHeaders) RangeHeaders.Add(path + " " + range);
                long start = 0;
                if (range != null && !IgnoreRange && range.StartsWith("bytes=") && range.EndsWith("-")) start = long.Parse(range.Substring(6, range.Length - 7));
                byte[] body = data.Skip((int)start).ToArray();
                if (AlwaysCorrupt || (CorruptFirst.ContainsKey(path) && hit <= CorruptFirst[path])) { body = body.Select(b => (byte)(b ^ 0xFF)).ToArray(); }
                c.Response.StatusCode = start > 0 ? 206 : 200;
                c.Response.ContentLength64 = body.Length;
                if (DropFirstAfter.ContainsKey(path) && hit == 1)
                {
                    int n = DropFirstAfter[path];
                    c.Response.OutputStream.Write(body, 0, n);
                    c.Response.OutputStream.Flush();
                    c.Response.Abort();
                    return;
                }
                c.Response.OutputStream.Write(body, 0, body.Length);
                c.Response.Close();
            }
            catch (Exception) { try { c.Response.Abort(); } catch (Exception) { } }
        }

        public void Dispose() { try { L.Stop(); L.Close(); } catch (Exception) { } }
    }

    static class Program
    {
        static string Sha(byte[] b) { using (var s = SHA256.Create()) return string.Concat(s.ComputeHash(b).Select(x => x.ToString("x2"))); }

        static byte[] Blob(int n, int seed) { var r = new Random(seed); var b = new byte[n]; r.NextBytes(b); return b; }

        static string ManifestJson(string version, Dictionary<string, byte[]> files, bool online = false, string message = "soon", bool relativeUrls = true)
        {
            var sb = new StringBuilder();
            sb.Append("{\"version\":\"" + version + "\",\"built_at\":\"2026-10-04T12:00:00Z\",\"rev\":\"abc1234\",\"files\":[");
            sb.Append(string.Join(",", files.Select(f => "{\"path\":\"" + f.Key + "\",\"size\":" + f.Value.Length + ",\"sha256\":\"" + Sha(f.Value) + "\"" + (relativeUrls ? "" : ",\"url\":\"" + f.Key + "\"") + "}")));
            sb.Append("],\"online\":{\"enabled\":" + (online ? "true" : "false") + ",\"message\":\"" + message + "\"}}");
            return sb.ToString();
        }

        static ClientManifest Parse(string json, string baseUrl = "https://muffindevelopment.com/death-muffin/client/manifest.json")
        {
            ClientManifest m; string err;
            return ClientManifest.TryParse(json, new Uri(baseUrl), out m, out err) ? m : null;
        }

        static int Main()
        {
            JsonTests(); ManifestTests(); VersionTests(); HashTests(); OnlineTests(); OfflineStateTests();
            InstallerTests().GetAwaiter().GetResult();
            return T.Done();
        }

        static void JsonTests()
        {
            var d = (Dictionary<string, object>)MiniJson.Parse(" {\"a\":[1,2.5,-3e2],\"b\":\"x\\n\\u0041\\\"\",\"c\":true,\"d\":null,\"e\":{}} ");
            T.Eq(((List<object>)d["a"]).Count, 3, "json array");
            T.Eq((double)((List<object>)d["a"])[2], -300.0, "json exponent");
            T.Eq((string)d["b"], "x\nA\"", "json escapes");
            T.Eq(d["c"], (object)true, "json true");
            T.Ok(d["d"] == null, "json null");
            foreach (string bad in new[] { "", "{", "{\"a\":}", "[1,]", "{\"a\":1} x", "\"abc", "{'a':1}", "tru" })
            {
                bool threw = false;
                try { MiniJson.Parse(bad); } catch (FormatException) { threw = true; }
                T.Ok(threw, "json rejects [" + bad + "]");
            }
        }

        static void ManifestTests()
        {
            var files = new Dictionary<string, byte[]> { { "DeathMuffin.exe", Blob(100, 1) }, { "DeathMuffin.pck", Blob(300, 2) }, { "bin/extra.dll", Blob(10, 3) } };
            var m = Parse(ManifestJson("20261004.120000-abc1234", files, false, "Online opens soon"));
            T.Ok(m != null, "valid manifest parses");
            if (m == null) return;
            T.Eq(m.Files.Count, 3, "file count");
            T.Eq(m.TotalBytes, 410L, "total bytes");
            T.Eq(m.Files[0].Url.ToString(), "https://muffindevelopment.com/death-muffin/client/DeathMuffin.exe", "url default");
            T.Ok(!m.OnlineEnabled, "online false");
            T.Eq(m.OnlineMessage, "Online opens soon", "online message");
            T.Ok(Parse(ManifestJson("20261004.120000-abc1234", files, true)).OnlineEnabled, "online true");
            T.Ok(Parse(ManifestJson("v1", files, false, "x", false)) != null, "relative url accepted");

            string good = ManifestJson("v1", files);
            T.Ok(Parse(good.Replace("DeathMuffin.exe", "../evil.exe")) == null, "path traversal rejected");
            T.Ok(Parse(good.Replace("bin/extra.dll", "/abs.dll")) == null, "absolute path rejected");
            T.Ok(Parse(good.Replace("bin/extra.dll", "bin\\\\extra.dll")) == null, "backslash path rejected");
            T.Ok(Parse(good.Replace("\"v1\"", "\"../v1\"")) == null, "unsafe version rejected");
            T.Ok(Parse(good.Replace(Sha(files["DeathMuffin.pck"]), "zz")) == null, "bad sha rejected");
            T.Ok(Parse("{\"version\":\"v1\",\"files\":[]}") == null, "empty files rejected");
            var noExe = new Dictionary<string, byte[]> { { "DeathMuffin.pck", Blob(5, 1) } };
            T.Ok(Parse(ManifestJson("v1", noExe)) == null, "missing exe rejected");
            T.Ok(Parse(good.Replace("\"size\":100", "\"size\":-1")) == null, "negative size rejected");
            T.Ok(Parse(good.Replace("\"size\":100", "\"size\":1.5")) == null, "fractional size rejected");
            T.Ok(Parse(ManifestJson("v1", files, false, "x", false).Replace("\"url\":\"bin/extra.dll\"", "\"url\":\"https://evil.example/x.dll\"")) == null, "cross-host url rejected");
            T.Ok(Parse("not json") == null, "garbage rejected");
            T.Ok(Parse("[]") == null, "array root rejected");
            // Online lock strictness: only a literal true unlocks.
            T.Ok(!Parse(good.Replace("\"enabled\":false", "\"enabled\":\"true\"")).OnlineEnabled, "string \"true\" stays locked");
            T.Ok(!Parse(good.Replace("\"enabled\":false", "\"enabled\":1")).OnlineEnabled, "number 1 stays locked");
            T.Ok(!Parse(good.Substring(0, good.IndexOf(",\"online\"")) + "}").OnlineEnabled, "missing online block stays locked");
        }

        static void VersionTests()
        {
            T.Eq(VersionCompare.Compare("20261004.120000-abc", "20261004.120001-def"), -1, "older < newer");
            T.Eq(VersionCompare.Compare("20261005.000000-a", "20261004.235959-b"), 1, "day rollover");
            T.Eq(VersionCompare.Compare("20261004.120000-abc", "20261004.120000-zzz"), 0, "same build different suffix");
            T.Eq(VersionCompare.Compare("1.2", "1.10"), -1, "numeric not lexical");
            T.Eq(VersionCompare.Compare("1.2", "1.2.0"), 0, "missing segment is zero");
            T.Eq(VersionCompare.Compare("alpha", "beta"), -1, "non-numeric falls back to ordinal");
            T.Eq(VersionCompare.Compare(null, "1"), -1, "null is oldest");
        }

        static void HashTests()
        {
            string dir = Path.Combine(Path.GetTempPath(), "dm-hash-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                string f = Path.Combine(dir, "a.bin");
                byte[] data = Blob(5000, 9);
                File.WriteAllBytes(f, data);
                T.Eq(Hashing.Sha256Hex(f), Sha(data), "sha256 matches");
                T.Ok(Hashing.Verify(f, data.Length, Sha(data).ToUpperInvariant()), "verify ok (case-insensitive)");
                T.Ok(!Hashing.Verify(f, data.Length + 1, Sha(data)), "verify wrong size");
                T.Ok(!Hashing.Verify(f, data.Length, new string('0', 64)), "verify wrong hash");
                T.Ok(!Hashing.Verify(Path.Combine(dir, "missing"), 1, Sha(data)), "verify missing file");
                File.WriteAllBytes(f, new byte[0]);
                T.Ok(Hashing.Verify(f, 0, Sha(new byte[0])), "verify empty file");
            }
            finally { Directory.Delete(dir, true); }
        }

        static void OnlineTests()
        {
            var files = new Dictionary<string, byte[]> { { "DeathMuffin.exe", Blob(10, 1) } };
            var locked = Parse(ManifestJson("v1", files, false, "Online opens soon"));
            var open = Parse(ManifestJson("v1", files, true));
            var u = OnlineGate.Compute(locked, "v1");
            T.Ok(!u.Enabled && u.Locked, "locked manifest -> disabled");
            T.Eq(u.Note, "Online opens soon", "lock label from manifest");
            u = OnlineGate.Compute(null, "v1");
            T.Ok(!u.Enabled && u.Locked, "unreadable manifest -> locked");
            T.Eq(u.Note, OnlineGate.DefaultMessage, "unreadable manifest default label");
            T.Ok(!OnlineGate.Compute(Parse(ManifestJson("v1", files, false, "  \r\n ")), "v1").Enabled, "blank message still locked");
            T.Eq(OnlineGate.Compute(Parse(ManifestJson("v1", files, false, "  \r\n ")), "v1").Note, OnlineGate.DefaultMessage, "blank message -> default");
            T.Ok(OnlineGate.Compute(Parse(ManifestJson("v1", files, false, new string('x', 200))), null).Note.Length <= 70, "long message trimmed");
            u = OnlineGate.Compute(open, "v1");
            T.Ok(u.Enabled && !u.Locked, "open + installed -> enabled");
            u = OnlineGate.Compute(open, null);
            T.Ok(!u.Enabled && !u.Locked, "open but not installed -> disabled, not locked");
            T.Ok(OnlineGate.IsOpen(open) && !OnlineGate.IsOpen(locked) && !OnlineGate.IsOpen(null), "IsOpen");
        }

        static OfflineUi Off(string installed, ClientManifest live, bool net = true, RunningMode run = RunningMode.None, bool dl = false, double prog = -1, bool failed = false, string err = null)
        {
            return OfflineStateMachine.Compute(new OfflineInputs { InstalledVersion = installed, Live = live, NetReachable = net, Running = run, Downloading = dl, Progress = prog, Failed = failed, Error = err });
        }

        static void OfflineStateTests()
        {
            var files = new Dictionary<string, byte[]> { { "DeathMuffin.exe", Blob(10, 1) } };
            var v2 = Parse(ManifestJson("20261004.120000-b", files));
            var u = Off(null, v2);
            T.Eq(u.Text, "DOWNLOAD OFFLINE GAME", "fresh: download text");
            T.Ok(u.Enabled && u.Action == OfflineAction.Download, "fresh: download enabled");
            u = Off(null, null, net: false);
            T.Ok(!u.Enabled && u.Action == OfflineAction.None && u.Note.Contains("No internet"), "fresh, offline: disabled");
            u = Off(null, null, net: true);
            T.Ok(!u.Enabled && u.Text.Contains("NOT AVAILABLE"), "fresh, nothing published: disabled");
            u = Off("20261004.120000-b", v2);
            T.Ok(u.Text == "PLAY OFFLINE" && u.Enabled && u.Action == OfflineAction.Play && !u.ShowPlayInstalledLink, "installed, current: play");
            u = Off("20261004.120000-b", null, net: false);
            T.Ok(u.Text == "PLAY OFFLINE" && u.Enabled && u.Action == OfflineAction.Play, "installed, no internet: play");
            u = Off("20261004.120000-b", null, net: true);
            T.Ok(u.Action == OfflineAction.Play, "installed, manifest unreadable: play");
            u = Off("20261003.120000-a", v2);
            T.Ok(u.Text == "UPDATE OFFLINE GAME" && u.Action == OfflineAction.Update && u.ShowPlayInstalledLink, "installed, older: update + play-installed link");
            u = Off("20261005.120000-c", v2);
            T.Ok(u.Action == OfflineAction.Play, "installed newer than live (rollback publish): never downgrade");
            u = Off("20261003.120000-a", v2, net: false);
            T.Ok(u.Action == OfflineAction.Play, "installed, older, no internet: play");
            u = Off(null, v2, dl: true, prog: 0.426);
            T.Ok(u.Text == "DOWNLOADING 42%" && !u.Enabled && u.ShowBar && Math.Abs(u.Bar - 0.426) < 1e-9, "downloading: percent, bar, disabled");
            u = Off(null, v2, dl: true);
            T.Eq(u.Text, "DOWNLOADING...", "downloading: unknown pct");
            u = Off("20261004.120000-b", v2, run: RunningMode.Offline);
            T.Ok(u.Text == "OFFLINE GAME RUNNING" && !u.Enabled, "offline running: disabled");
            u = Off("20261004.120000-b", v2, run: RunningMode.Online);
            T.Ok(u.Enabled && u.Action == OfflineAction.Play, "online running: offline play still offered (asks to close)");
            u = Off(null, v2, failed: true, err: "boom");
            T.Ok(u.Text == "RETRY DOWNLOAD" && u.Enabled && u.Action == OfflineAction.Download && u.Warn && u.Note == "boom" && !u.ShowPlayInstalledLink, "failed fresh: retry download");
            u = Off("20261003.120000-a", v2, failed: true);
            T.Ok(u.Action == OfflineAction.Update && u.ShowPlayInstalledLink, "failed update: retry update + play installed");
            u = Off(null, null, net: false, failed: true);
            T.Ok(!u.Enabled, "failed and offline: retry disabled");
        }

        static async Task InstallerTests()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "dm-inst-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tmp);
            try
            {
                using (var http = new HttpClient())
                using (var srv = new TestServer())
                {
                    var exe = Blob(200000, 11); var pck = Blob(900000, 12); var dll = Blob(3000, 13);
                    srv.Files["DeathMuffin.exe"] = exe; srv.Files["DeathMuffin.pck"] = pck; srv.Files["bin/x.dll"] = dll;
                    var files = new Dictionary<string, byte[]> { { "DeathMuffin.exe", exe }, { "DeathMuffin.pck", pck }, { "bin/x.dll", dll } };
                    ClientManifest m; string err;
                    T.Ok(ClientManifest.TryParse(ManifestJson("20261004.120000-aaa", files), new Uri(srv.Base + "manifest.json"), out m, out err), "test manifest parses " + err);

                    string root = Path.Combine(tmp, "client");
                    Func<ClientInstaller> mk = () => new ClientInstaller(http, root) { RetryDelay = TimeSpan.FromMilliseconds(10), StallTimeout = TimeSpan.FromSeconds(5) };
                    T.Ok(ClientStore.ReadInstalled(root) == null, "nothing installed yet");

                    // 1. Fresh install with progress.
                    var seen = new List<double>();
                    await mk().InstallAsync(m, null, new SyncProgress(p => seen.Add(p.Fraction)), CancellationToken.None);
                    var inst = ClientStore.ReadInstalled(root);
                    T.Ok(inst != null && inst.Version == m.Version, "installed after first run");
                    T.Ok(inst != null && File.Exists(inst.ExePath) && Hashing.Verify(inst.ExePath, exe.Length, Sha(exe)), "exe verified on disk");
                    T.Ok(inst != null && Hashing.Verify(Path.Combine(inst.Dir, "bin", "x.dll"), dll.Length, Sha(dll)), "nested file verified");
                    T.Ok(seen.Count > 3 && Math.Abs(seen.Last() - 1.0) < 1e-9, "progress reaches 100%");
                    T.Ok(seen.Zip(seen.Skip(1), (a, b) => b >= a - 1e-12).All(x => x), "progress never goes backwards");
                    T.Ok(!Directory.Exists(Path.Combine(root, ".staging-" + m.Version)), "staging folder gone after swap");
                    T.Ok(File.ReadAllText(Path.Combine(root, "current.json")).Contains(m.Version), "current.json written");

                    // 2. Tampered install is no longer reported as installed (size check).
                    string pckPath = Path.Combine(inst.Dir, "DeathMuffin.pck");
                    File.WriteAllBytes(pckPath, new byte[10]);
                    T.Ok(ClientStore.ReadInstalled(root) == null, "wrong-size file -> not installed");
                    File.WriteAllBytes(pckPath, pck);
                    T.Ok(ClientStore.ReadInstalled(root) != null, "restored -> installed again");

                    // 3. Update to v2: pck changes, exe/dll unchanged -> only the pck is downloaded; old version pruned.
                    var pck2 = Blob(850000, 22);
                    srv.Files["DeathMuffin.pck"] = pck2;
                    var files2 = new Dictionary<string, byte[]> { { "DeathMuffin.exe", exe }, { "DeathMuffin.pck", pck2 }, { "bin/x.dll", dll } };
                    ClientManifest m2;
                    ClientManifest.TryParse(ManifestJson("20261004.130000-bbb", files2), new Uri(srv.Base + "manifest.json"), out m2, out err);
                    srv.Hits.Clear();
                    await mk().InstallAsync(m2, inst, null, CancellationToken.None);
                    var inst2 = ClientStore.ReadInstalled(root);
                    T.Ok(inst2 != null && inst2.Version == m2.Version, "v2 current");
                    T.Ok(!srv.Hits.ContainsKey("DeathMuffin.exe") && !srv.Hits.ContainsKey("bin/x.dll") && srv.Hits.ContainsKey("DeathMuffin.pck"), "unchanged files reused locally, only the changed one downloaded");
                    T.Ok(inst2 != null && Hashing.Verify(Path.Combine(inst2.Dir, "DeathMuffin.pck"), pck2.Length, Sha(pck2)), "v2 pck verified");
                    T.Ok(Directory.Exists(inst.Dir), "previous version kept for one generation");

                    // 4. Failed update leaves the installed version untouched (permanent corruption -> checksum mismatch every attempt).
                    var pck3 = Blob(400000, 33);
                    srv.Files["DeathMuffin.pck"] = pck3;
                    ClientManifest m3;
                    ClientManifest.TryParse(ManifestJson("20261004.140000-ccc", new Dictionary<string, byte[]> { { "DeathMuffin.exe", exe }, { "DeathMuffin.pck", pck3 }, { "bin/x.dll", dll } }), new Uri(srv.Base + "manifest.json"), out m3, out err);
                    srv.AlwaysCorrupt = true;
                    bool threw = false;
                    try { await mk().InstallAsync(m3, inst2, null, CancellationToken.None); } catch (IOException) { threw = true; }
                    srv.AlwaysCorrupt = false;
                    T.Ok(threw, "permanently corrupt download fails");
                    var still = ClientStore.ReadInstalled(root);
                    T.Ok(still != null && still.Version == m2.Version, "failed update keeps the working version installed");
                    T.Ok(!File.Exists(Path.Combine(root, ".staging-" + m3.Version, "DeathMuffin.pck.part")), "bad bytes are not kept for resume");

                    // 5. Transient corruption is retried and succeeds; a dropped connection resumes with a Range request.
                    srv.CorruptFirst["DeathMuffin.pck"] = 1;
                    srv.Hits.Clear(); srv.RangeHeaders.Clear();
                    await mk().InstallAsync(m3, inst2, null, CancellationToken.None);
                    var inst3 = ClientStore.ReadInstalled(root);
                    T.Ok(inst3 != null && inst3.Version == m3.Version, "retry after one corrupt response succeeds");
                    T.Ok(srv.Hits["DeathMuffin.pck"] == 2, "corrupt file fetched twice");
                    T.Ok(!Directory.Exists(inst.Dir), "generation before previous is pruned");
                    T.Ok(Directory.Exists(inst2.Dir), "previous version still kept");

                    string root2 = Path.Combine(tmp, "client2");
                    var big = Blob(1500000, 44);
                    srv.Files["DeathMuffin.exe"] = big; srv.Files["DeathMuffin.pck"] = pck3;
                    ClientManifest mb;
                    ClientManifest.TryParse(ManifestJson("20261004.150000-ddd", new Dictionary<string, byte[]> { { "DeathMuffin.exe", big }, { "DeathMuffin.pck", pck3 } }), new Uri(srv.Base + "manifest.json"), out mb, out err);
                    srv.CorruptFirst.Clear(); srv.Hits.Clear(); srv.RangeHeaders.Clear();
                    srv.DropFirstAfter["DeathMuffin.exe"] = 600000;
                    await new ClientInstaller(http, root2) { RetryDelay = TimeSpan.FromMilliseconds(10), StallTimeout = TimeSpan.FromSeconds(5) }.InstallAsync(mb, null, null, CancellationToken.None);
                    T.Ok(ClientStore.ReadInstalled(root2) != null, "install completes after dropped connection");
                    T.Ok(srv.RangeHeaders.Any(h => h.StartsWith("DeathMuffin.exe bytes=") && !h.EndsWith("bytes=0-")), "resumed with a Range request: " + string.Join("|", srv.RangeHeaders));

                    // 6. Interrupted run (cancel) keeps finished files; the next run only fetches the rest.
                    string root3 = Path.Combine(tmp, "client3");
                    srv.DropFirstAfter.Clear(); srv.Hits.Clear();
                    var cts = new CancellationTokenSource();
                    bool cancelled = false;
                    try
                    {
                        // Files are installed in manifest order: cancel once the exe (first) is complete.
                        await new ClientInstaller(http, root3) { RetryDelay = TimeSpan.FromMilliseconds(10) }.InstallAsync(mb, null, new SyncProgress(p => { if (p.File == "DeathMuffin.exe" && p.Done >= big.Length) cts.Cancel(); }), cts.Token);
                    }
                    catch (OperationCanceledException) { cancelled = true; }
                    T.Ok(cancelled, "cancel stops the install");
                    T.Ok(ClientStore.ReadInstalled(root3) == null, "cancelled install is not installed");
                    srv.Hits.Clear();
                    await new ClientInstaller(http, root3) { RetryDelay = TimeSpan.FromMilliseconds(10) }.InstallAsync(mb, null, null, CancellationToken.None);
                    T.Ok(ClientStore.ReadInstalled(root3) != null, "second run completes");
                    T.Ok(!srv.Hits.ContainsKey("DeathMuffin.exe"), "finished file kept across the interruption");

                    // 7. Server ignoring Range (200 instead of 206) is handled by restarting the file.
                    string root4 = Path.Combine(tmp, "client4");
                    Directory.CreateDirectory(Path.Combine(root4, ".staging-" + mb.Version));
                    File.WriteAllBytes(Path.Combine(root4, ".staging-" + mb.Version, "DeathMuffin.exe.part"), big.Take(1000).ToArray());
                    srv.IgnoreRange = true;
                    await new ClientInstaller(http, root4) { RetryDelay = TimeSpan.FromMilliseconds(10) }.InstallAsync(mb, null, null, CancellationToken.None);
                    srv.IgnoreRange = false;
                    T.Ok(ClientStore.ReadInstalled(root4) != null, "range-ignoring server still yields a verified install");

                    // 8. 404 fails cleanly.
                    srv.Files.Remove("DeathMuffin.pck");
                    string root5 = Path.Combine(tmp, "client5");
                    threw = false;
                    try { await new ClientInstaller(http, root5) { RetryDelay = TimeSpan.FromMilliseconds(5), MaxAttempts = 2 }.InstallAsync(mb, null, null, CancellationToken.None); } catch (IOException) { threw = true; }
                    T.Ok(threw && ClientStore.ReadInstalled(root5) == null, "404 fails and installs nothing");
                }
            }
            finally { try { Directory.Delete(tmp, true); } catch (Exception) { } }
        }

        sealed class SyncProgress : IProgress<InstallProgress>
        {
            readonly Action<InstallProgress> a;
            public SyncProgress(Action<InstallProgress> a) { this.a = a; }
            public void Report(InstallProgress v) { a(v); }
        }
    }
}
