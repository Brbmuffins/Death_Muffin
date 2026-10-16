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
            JsonTests(); ManifestTests(); VersionTests(); HashTests(); OnlineTests(); PlayStateTests();
            InstallerTests().GetAwaiter().GetResult();
            ChannelTests(); SettingsTests(); ChannelInstallTests().GetAwaiter().GetResult();
            SelfUpdateLogicTests(); SelfUpdateFileTests().GetAwaiter().GetResult();
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
            T.Eq(OnlineGate.Notice(locked, true), "Online opens soon", "lock note from manifest");
            T.Eq(OnlineGate.Notice(null, true), OnlineGate.DefaultMessage, "unreadable manifest default note");
            T.Eq(OnlineGate.Notice(Parse(ManifestJson("v1", files, false, "  \r\n ")), true), OnlineGate.DefaultMessage, "blank message -> default");
            T.Ok(OnlineGate.Notice(Parse(ManifestJson("v1", files, false, new string('x', 200))), true).Length <= 70, "long message trimmed");
            T.Eq(OnlineGate.Notice(open, true), "", "open: no note");
            T.Eq(OnlineGate.Notice(open, false), OnlineGate.NoInternetNote, "no internet note wins");
            T.Eq(OnlineGate.Notice(null, false), OnlineGate.NoInternetNote, "no internet, no manifest");
            T.Ok(OnlineGate.IsOpen(open) && !OnlineGate.IsOpen(locked) && !OnlineGate.IsOpen(null), "IsOpen");
            // staff mode: enabled:false + staff:true. The launcher cannot know if the user is staff, so it is "not open" (message shown, PLAY still allowed).
            string baseJson = ManifestJson("v1", files, false, "Online opens soon");
            var staff = Parse(baseJson.Replace("\"enabled\":false", "\"enabled\":false,\"staff\":true"));
            T.Ok(staff.OnlineStaff && !staff.OnlineEnabled && !OnlineGate.IsOpen(staff), "staff mode: not open for everyone");
            T.Eq(OnlineGate.Notice(staff, true), "Online opens soon", "staff mode: manifest message");
            T.Ok(!Parse(baseJson.Replace("\"enabled\":false", "\"enabled\":false,\"staff\":\"true\"")).OnlineStaff, "string staff stays locked");
            T.Ok(!Parse(baseJson.Replace("\"enabled\":false", "\"enabled\":false,\"staff\":1")).OnlineStaff, "number staff stays locked");
            T.Ok(!locked.OnlineStaff && !open.OnlineStaff, "old manifests carry no staff flag");
        }

        static PlayUi Off(string installed, ClientManifest live, bool net = true, bool run = false, bool dl = false, double prog = -1, bool failed = false, string err = null)
        {
            return PlayStateMachine.Compute(new PlayInputs { InstalledVersion = installed, Live = live, NetReachable = net, Running = run, Downloading = dl, Progress = prog, Failed = failed, Error = err });
        }

        static void PlayStateTests()
        {
            var files = new Dictionary<string, byte[]> { { "DeathMuffin.exe", Blob(10, 1) } };
            var v2 = Parse(ManifestJson("20261004.120000-b", files));          // online closed
            var v2open = Parse(ManifestJson("20261004.120000-b", files, true)); // online open
            var u = Off(null, v2);
            T.Eq(u.Text, "DOWNLOAD GAME", "fresh: download text");
            T.Ok(u.Enabled && u.Action == PlayAction.Download, "fresh: download enabled");
            u = Off(null, null, net: false);
            T.Ok(!u.Enabled && u.Action == PlayAction.None && u.Note.Contains("No internet"), "fresh, offline: disabled");
            u = Off(null, null, net: true);
            T.Ok(!u.Enabled && u.Text.Contains("NOT AVAILABLE"), "fresh, nothing published: disabled");
            u = Off("20261004.120000-b", v2open);
            T.Ok(u.Text == "PLAY" && u.Enabled && u.Action == PlayAction.Play && !u.ShowPlayInstalledLink && u.Notice == "", "installed, current, online open: play, no note");
            u = Off("20261004.120000-b", v2);
            T.Ok(u.Text == "PLAY" && u.Enabled && u.Action == PlayAction.Play && u.Notice == "soon" && u.FullNote.EndsWith("soon"), "online closed: play still enabled + manifest message");
            u = Off("20261004.120000-b", v2, net: false);
            T.Ok(u.Text == "PLAY" && u.Enabled && u.Action == PlayAction.Play && u.Notice == OnlineGate.NoInternetNote, "installed, no internet: play + sign-in note");
            u = Off("20261004.120000-b", null, net: false);
            T.Ok(u.Enabled && u.Action == PlayAction.Play && u.Notice == OnlineGate.NoInternetNote, "installed, no manifest, no internet: play");
            u = Off("20261004.120000-b", null, net: true);
            T.Ok(u.Enabled && u.Action == PlayAction.Play && u.Notice == OnlineGate.DefaultMessage, "installed, manifest unreadable: play + default note");
            u = Off("20261003.120000-a", v2open);
            T.Ok(u.Text == "UPDATE GAME" && u.Action == PlayAction.Update && u.ShowPlayInstalledLink, "installed, older: update + play-installed link");
            u = Off("20261003.120000-a", v2);
            T.Ok(u.Action == PlayAction.Update && u.Notice == "soon", "update with online closed keeps the note");
            u = Off("20261005.120000-c", v2open);
            T.Ok(u.Action == PlayAction.Play, "installed newer than live (rollback publish): never downgrade");
            u = Off("20261003.120000-a", v2, net: false);
            T.Ok(u.Action == PlayAction.Play, "installed, older, no internet: play");
            u = Off(null, v2, dl: true, prog: 0.426);
            T.Ok(u.Text == "DOWNLOADING 42%" && !u.Enabled && u.ShowBar && Math.Abs(u.Bar - 0.426) < 1e-9, "downloading: percent, bar, disabled");
            u = Off(null, v2, dl: true);
            T.Eq(u.Text, "DOWNLOADING...", "downloading: unknown pct");
            u = Off("20261004.120000-b", v2, run: true);
            T.Ok(u.Text == "GAME RUNNING" && !u.Enabled && u.Action == PlayAction.None, "running: disabled");
            u = Off(null, v2, failed: true, err: "boom");
            T.Ok(u.Text == "RETRY DOWNLOAD" && u.Enabled && u.Action == PlayAction.Download && u.Warn && u.Note == "boom" && !u.ShowPlayInstalledLink, "failed fresh: retry download");
            u = Off("20261003.120000-a", v2, failed: true);
            T.Ok(u.Action == PlayAction.Update && u.ShowPlayInstalledLink, "failed update: retry update + play installed");
            u = Off(null, null, net: false, failed: true);
            T.Ok(!u.Enabled, "failed and offline: retry disabled");
            // One short footer status per state, with its indicator colour (the long note is the tooltip).
            T.Ok(Off("20261004.120000-b", v2open).Status == "Ready to play" && Off("20261004.120000-b", v2open).Level == StatusLevel.Ok, "status: ready (green)");
            T.Ok(Off("20261004.120000-b", v2).Status == "soon" && Off("20261004.120000-b", v2).Level == StatusLevel.Warn, "status: online closed shows the manifest message (orange)");
            T.Ok(Off("20261004.120000-b", v2, run: true).Status == "Game running" && Off("20261004.120000-b", v2, run: true).Level == StatusLevel.Ok, "status: game running");
            T.Ok(Off("20261003.120000-a", v2open).Status.StartsWith("Update ready") && Off("20261003.120000-a", v2open).Level == StatusLevel.Busy, "status: update ready (violet)");
            T.Ok(Off(null, v2, dl: true, prog: 0.5).Level == StatusLevel.Busy && !Off(null, v2, dl: true, prog: 0.5).Status.Contains("%"), "status: downloading, percent only on the button");
            T.Ok(Off(null, v2, failed: true).Level == StatusLevel.Warn, "status: failed download (orange)");
            T.Ok(Off(null, null, net: false).Status == "No internet connection" && Off(null, null, net: false).Level == StatusLevel.Warn, "status: no internet");
            foreach (var x in new[] { Off(null, v2), Off("20261004.120000-b", v2open), Off("20261003.120000-a", v2open), Off(null, v2, dl: true), Off("20261004.120000-b", v2, run: true), Off(null, v2, failed: true), Off(null, null, net: false), Off(null, null) })
                T.Ok(x.Status.Length > 0 && x.Status.Length <= 40, "status is short: " + x.Status);
            // No player-facing text may mention the retired offline edition.
            foreach (var x in new[] { Off(null, v2), Off("a", v2), Off("20261004.120000-b", v2), Off("20261004.120000-b", v2, run: true), Off(null, null, net: false), Off("20261004.120000-b", null, net: false), Off(null, null) })
                T.Ok(!(x.Text + x.FullNote).ToLowerInvariant().Contains("offline"), "no 'offline' wording: " + x.Text);
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

        // ---- Channels: the normal game and the team-only test build (DECISIONS B38) ----

        static void ChannelTests()
        {
            // Live stays exactly as it always was.
            T.Eq(Channels.FolderName(ClientChannel.Live), "client", "live folder");
            T.Eq(Channels.ManifestUrl(ClientChannel.Live), "https://muffindevelopment.com/death-muffin/client/manifest.json", "live manifest url unchanged");
            T.Eq(Channels.NotesBaseUrl(ClientChannel.Live), "https://muffindevelopment.com/death-muffin/play/", "live notes url unchanged");
            T.Eq(Channels.InstallDir(Path.Combine("a", "DeathMuffin"), ClientChannel.Live), Path.Combine("a", "DeathMuffin", "client"), "live install dir unchanged");
            T.Eq(Channels.Marker(ClientChannel.Live), "", "live has no marker");
            // The test channel: own folder, own manifest on the same host.
            T.Eq(Channels.FolderName(ClientChannel.Test), "client-test", "test folder");
            T.Eq(Channels.ManifestUrl(ClientChannel.Test), "https://muffindevelopment.com/death-muffin/client-test/manifest.json", "test manifest url");
            T.Eq(Channels.BaseUrl(ClientChannel.Test), "https://muffindevelopment.com/death-muffin/client-test/", "test base url");
            T.Eq(Channels.NotesBaseUrl(ClientChannel.Test), "https://muffindevelopment.com/death-muffin/client-test/", "test notes live next to the test manifest");
            T.Eq(Channels.InstallDir(Path.Combine("a", "DeathMuffin"), ClientChannel.Test), Path.Combine("a", "DeathMuffin", "client-test"), "test install dir");
            T.Eq(Channels.Marker(ClientChannel.Test), "TEST BUILD", "test marker");
            T.Eq(new Uri(Channels.ManifestUrl(ClientChannel.Test)).Host, new Uri(Channels.ManifestUrl(ClientChannel.Live)).Host, "same host for both manifests");
            // Siblings, never nested: pruning or deleting one folder cannot reach the other.
            string liveDir = Channels.InstallDir("root", ClientChannel.Live), testDir = Channels.InstallDir("root", ClientChannel.Test);
            T.Ok(liveDir != testDir && !testDir.StartsWith(liveDir + Path.DirectorySeparatorChar) && !liveDir.StartsWith(testDir + Path.DirectorySeparatorChar), "install dirs are separate siblings");
            T.Ok(ClientChannel.Live == Channels.Of(false) && ClientChannel.Test == Channels.Of(true), "setting -> channel");
            T.Ok(default(ClientChannel) == ClientChannel.Live, "a default channel is the normal game");

            // The hidden switch: Ctrl+click on Settings, or already on (so it can be turned off). A plain click by a player never shows it.
            T.Ok(!Channels.ShowTestSwitch(false, false), "plain click: switch hidden");
            T.Ok(Channels.ShowTestSwitch(false, true), "Ctrl+click: switch shown");
            T.Ok(Channels.ShowTestSwitch(true, false), "test build on: switch shown so it can be turned off");
            T.Ok(Channels.ShowTestSwitch(true, true), "test build on + Ctrl: shown");

            // A test manifest is parsed and verified exactly like the live one (same host rule, same checks), against its own URL.
            var files = new Dictionary<string, byte[]> { { "DeathMuffin.exe", Blob(10, 1) }, { "DeathMuffin.pck", Blob(20, 2) } };
            var tm = Parse(ManifestJson("20261020.100000-t1", files), Channels.ManifestUrl(ClientChannel.Test));
            T.Ok(tm != null && tm.Files[0].Url.ToString() == "https://muffindevelopment.com/death-muffin/client-test/DeathMuffin.exe", "test manifest files resolve under client-test");
            T.Ok(Parse(ManifestJson("v1", files, false, "x", false).Replace("\"url\":\"DeathMuffin.exe\"", "\"url\":\"https://evil.example/DeathMuffin.exe\""), Channels.ManifestUrl(ClientChannel.Test)) == null, "test manifest: cross-host url rejected too");
            T.Ok(Parse("{\"version\":\"v1\",\"files\":[]}", Channels.ManifestUrl(ClientChannel.Test)) == null, "test manifest: empty files rejected too");

            // The button, status and texts name the test build; the live wording is untouched.
            var live = Parse(ManifestJson("20261004.120000-b", files));
            Func<string, bool, bool, bool, bool, PlayUi> test = (inst, run, dl, failed, net) => PlayStateMachine.Compute(new PlayInputs { InstalledVersion = inst, Live = tm, NetReachable = net, Running = run, Downloading = dl, Failed = failed, Channel = ClientChannel.Test });
            var tmOpen = Parse(ManifestJson("20261020.100000-t1", files, true), Channels.ManifestUrl(ClientChannel.Test));
            var u = test(null, false, false, false, true);
            T.Ok(u.Text == "DOWNLOAD TEST BUILD" && u.Enabled && u.Action == PlayAction.Download && u.Note.Contains("test build"), "test: download text");
            u = test("20261020.100000-t1", false, false, false, true);
            T.Ok(u.Text == "PLAY TEST BUILD" && u.Enabled && u.Action == PlayAction.Play && u.Notice == "soon", "test: play text, online note from the test manifest");
            u = PlayStateMachine.Compute(new PlayInputs { InstalledVersion = "20261020.100000-t1", Live = tmOpen, NetReachable = true, Channel = ClientChannel.Test });
            T.Ok(u.Text == "PLAY TEST BUILD" && u.Status == "Test build ready to play", "test: ready status");
            u = test("20261019.100000-t0", false, false, false, true);
            T.Ok(u.Text == "UPDATE TEST BUILD" && u.Action == PlayAction.Update && u.ShowPlayInstalledLink, "test: update text");
            u = test("20261020.100000-t1", true, false, false, true);
            T.Ok(u.Text == "TEST BUILD RUNNING" && !u.Enabled && u.Status == "Test build running", "test: running text");
            u = PlayStateMachine.Compute(new PlayInputs { InstalledVersion = null, Live = null, NetReachable = true, Channel = ClientChannel.Test });
            T.Ok(u.Text == "TEST BUILD NOT PUBLISHED" && !u.Enabled && u.Action == PlayAction.None, "test: nothing published yet");
            foreach (var x in new[] { test(null, false, false, false, true), test("a", false, false, false, true), test("20261020.100000-t1", true, false, false, true), test(null, false, false, false, false), test(null, false, true, false, true), test(null, false, false, true, true) })
                T.Ok(x.Text.Length <= 28 && x.Status.Length > 0 && x.Status.Length <= 40, "test texts fit the button and footer: " + x.Text + " / " + x.Status);
            // Same decisions on both channels.
            foreach (var inst in new string[] { null, "20261003.000000-a", "20261004.120000-b" })
            {
                var a = PlayStateMachine.Compute(new PlayInputs { InstalledVersion = inst, Live = live, NetReachable = true });
                var b = PlayStateMachine.Compute(new PlayInputs { InstalledVersion = inst, Live = live, NetReachable = true, Channel = ClientChannel.Test });
                T.Ok(a.Action == b.Action && a.Enabled == b.Enabled && a.ShowPlayInstalledLink == b.ShowPlayInstalledLink, "same action on both channels for installed=" + (inst ?? "none"));
            }
            var liveOpen = Parse(ManifestJson("20261004.120000-b", files, true));
            u = PlayStateMachine.Compute(new PlayInputs { InstalledVersion = "20261004.120000-b", Live = liveOpen, NetReachable = true });
            T.Ok(u.Text == "PLAY" && u.Status == "Ready to play", "live wording unchanged");
        }

        static void SettingsTests()
        {
            var d = new Settings();
            T.Ok(d.HighPerformanceGpu && !d.TestBuild, "defaults: high-performance GPU on, test build off");
            T.Eq(d.Channel, ClientChannel.Live, "default channel is live");
            T.Eq(d.ToJson(), "{\"HighPerformanceGpu\":true,\"TestBuild\":false}", "default json");

            string dir = Path.Combine(Path.GetTempPath(), "dm-settings-" + Guid.NewGuid().ToString("N"));
            string file = Path.Combine(dir, "sub", "launcher-settings.json");
            try
            {
                T.Ok(!Settings.Load(file).TestBuild && Settings.Load(file).HighPerformanceGpu, "no file: defaults");
                var s = new Settings { HighPerformanceGpu = false, TestBuild = true };
                s.Save(file);
                T.Ok(File.Exists(file), "save creates the folder and the file");
                var back = Settings.Load(file);
                T.Ok(!back.HighPerformanceGpu && back.TestBuild && back.Channel == ClientChannel.Test, "round trip: both values kept");
                new Settings { HighPerformanceGpu = true, TestBuild = false }.Save(file);
                back = Settings.Load(file);
                T.Ok(back.HighPerformanceGpu && !back.TestBuild, "round trip: switching back to live is saved");
                new Settings { HighPerformanceGpu = true, TestBuild = true }.Save(file);
                T.Ok(Settings.Load(file).TestBuild, "round trip: test build on again");

                // A file written by an older launcher (no TestBuild key) keeps the player on the normal game.
                File.WriteAllText(file, "{\"HighPerformanceGpu\":false}");
                back = Settings.Load(file);
                T.Ok(!back.HighPerformanceGpu && !back.TestBuild, "old settings file: gpu kept, test build off");
                // Odd or broken files fall back to defaults, never to the test build.
                foreach (string bad in new[] { "", "not json", "[]", "{", "{\"TestBuild\":\"true\"}", "{\"TestBuild\":1}", "{\"TestBuild\":null}", "{\"HighPerformanceGpu\":\"no\"}" })
                {
                    File.WriteAllText(file, bad);
                    var r = Settings.Load(file);
                    T.Ok(!r.TestBuild && r.HighPerformanceGpu, "unusable settings [" + bad + "] -> defaults");
                }
                File.WriteAllText(file, "{\"Future\":{\"a\":[1]},\"TestBuild\":true,\"HighPerformanceGpu\":true}");
                T.Ok(Settings.Load(file).TestBuild, "unknown keys are ignored");
                // A UTF-8 BOM from a hand edit is fine.
                File.WriteAllText(file, "﻿{\"TestBuild\":true}");
                T.Ok(Settings.Load(file).TestBuild, "BOM tolerated");
            }
            finally { try { Directory.Delete(dir, true); } catch (Exception) { } }
            T.Eq(Settings.InstallDir(ClientChannel.Live), Path.Combine(Settings.Root, "client"), "Settings.InstallDir live");
            T.Eq(Settings.InstallDir(ClientChannel.Test), Path.Combine(Settings.Root, "client-test"), "Settings.InstallDir test");
        }

        /// <summary>Both channels installed side by side with the real installer: each is read, updated and pruned on its own.</summary>
        static async Task ChannelInstallTests()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "dm-chan-" + Guid.NewGuid().ToString("N"));
            string appRoot = Path.Combine(tmp, "DeathMuffin");
            Directory.CreateDirectory(appRoot);
            try
            {
                using (var http = new HttpClient())
                using (var srv = new TestServer())
                {
                    string liveRoot = Channels.InstallDir(appRoot, ClientChannel.Live), testRoot = Channels.InstallDir(appRoot, ClientChannel.Test);
                    Func<string, string, ClientManifest> manifest = (version, pckName) =>
                    {
                        var f = new Dictionary<string, byte[]> { { "DeathMuffin.exe", srv.Files["DeathMuffin.exe"] }, { "DeathMuffin.pck", srv.Files["DeathMuffin.pck"] } };
                        ClientManifest m; string err;
                        if (!ClientManifest.TryParse(ManifestJson(version, f), new Uri(srv.Base + "manifest.json"), out m, out err)) throw new Exception(pckName + ": " + err);
                        return m;
                    };
                    Func<string, ClientInstaller> mk = root => new ClientInstaller(http, root) { RetryDelay = TimeSpan.FromMilliseconds(10), StallTimeout = TimeSpan.FromSeconds(5) };

                    // The normal game, installed first.
                    srv.Files["DeathMuffin.exe"] = Blob(50000, 51); srv.Files["DeathMuffin.pck"] = Blob(120000, 52);
                    var live1 = manifest("20261004.120000-live1", "live1");
                    await mk(liveRoot).InstallAsync(live1, null, null, CancellationToken.None);
                    string liveCurrent = File.ReadAllText(Path.Combine(liveRoot, "current.json"));

                    // The test build next to it: different content, different version.
                    srv.Files["DeathMuffin.exe"] = Blob(60000, 53); srv.Files["DeathMuffin.pck"] = Blob(130000, 54);
                    var test1 = manifest("20261020.090000-test1", "test1");
                    T.Ok(ClientStore.ReadInstalled(testRoot) == null, "test channel starts empty while the game is installed");
                    await mk(testRoot).InstallAsync(test1, null, null, CancellationToken.None);
                    var li = ClientStore.ReadInstalled(liveRoot); var ti = ClientStore.ReadInstalled(testRoot);
                    T.Ok(li != null && li.Version == live1.Version, "live install unchanged by the test install");
                    T.Ok(ti != null && ti.Version == test1.Version, "test build installed");
                    T.Ok(li != null && ti != null && li.Dir != ti.Dir && !ti.Dir.StartsWith(liveRoot + Path.DirectorySeparatorChar), "installs live in different folders");
                    T.Eq(File.ReadAllText(Path.Combine(liveRoot, "current.json")), liveCurrent, "live current.json untouched");

                    // Updating the test build (twice, so pruning runs) never touches the game.
                    var test2 = manifest("20261020.100000-test2", "test2");
                    await mk(testRoot).InstallAsync(test2, ti, null, CancellationToken.None);
                    var test3 = manifest("20261020.110000-test3", "test3");
                    await mk(testRoot).InstallAsync(test3, ClientStore.ReadInstalled(testRoot), null, CancellationToken.None);
                    T.Eq(ClientStore.ReadInstalled(testRoot).Version, test3.Version, "test build updated");
                    li = ClientStore.ReadInstalled(liveRoot);
                    T.Ok(li != null && li.Version == live1.Version && Directory.Exists(li.Dir), "pruning the test folder leaves the game alone");
                    T.Ok(!Directory.Exists(Path.Combine(testRoot, test1.Version)), "test folder pruned on its own");

                    // Updating the game never touches the test build.
                    srv.Files["DeathMuffin.exe"] = Blob(50000, 55); srv.Files["DeathMuffin.pck"] = Blob(121000, 56);
                    var live2 = manifest("20261005.120000-live2", "live2");
                    await mk(liveRoot).InstallAsync(live2, li, null, CancellationToken.None);
                    T.Eq(ClientStore.ReadInstalled(liveRoot).Version, live2.Version, "game updated");
                    T.Eq(ClientStore.ReadInstalled(testRoot).Version, test3.Version, "test build untouched by a game update");

                    // A failed test update keeps the working test build, and the game is still fine.
                    srv.Files["DeathMuffin.pck"] = Blob(100000, 57);
                    var test4 = manifest("20261020.120000-test4", "test4");
                    srv.AlwaysCorrupt = true;
                    bool threw = false;
                    try { await mk(testRoot).InstallAsync(test4, ClientStore.ReadInstalled(testRoot), null, CancellationToken.None); } catch (IOException) { threw = true; }
                    srv.AlwaysCorrupt = false;
                    T.Ok(threw && ClientStore.ReadInstalled(testRoot).Version == test3.Version && ClientStore.ReadInstalled(liveRoot).Version == live2.Version, "failed test update keeps both working");

                    // Removing the test install (switching back for good) leaves the game.
                    Directory.Delete(testRoot, true);
                    T.Ok(ClientStore.ReadInstalled(testRoot) == null && ClientStore.ReadInstalled(liveRoot).Version == live2.Version, "deleting client-test leaves client intact");
                }
            }
            finally { try { Directory.Delete(tmp, true); } catch (Exception) { } }
        }

        static LauncherManifest ParseLauncher(string json, string baseUrl = "https://muffindevelopment.com/death-muffin/launcher/manifest.json")
        {
            LauncherManifest m; string err;
            return LauncherManifest.TryParse(json, new Uri(baseUrl), out m, out err) ? m : null;
        }

        static string LauncherJson(string version, string url, long size, string sha)
        {
            return "{\"version\":\"" + version + "\",\"url\":\"" + url + "\",\"size\":" + size + ",\"sha256\":\"" + sha + "\"}";
        }

        static void SelfUpdateLogicTests()
        {
            string sha = new string('a', 64);
            var m = ParseLauncher(LauncherJson("0.9.0", "0.9.0/DeathMuffinLauncher.exe", 1000, sha));
            T.Ok(m != null && m.Version == "0.9.0" && m.Size == 1000, "launcher manifest parses");
            T.Eq(m.Url.ToString(), "https://muffindevelopment.com/death-muffin/launcher/0.9.0/DeathMuffinLauncher.exe", "launcher url resolves against the manifest");
            T.Ok(ParseLauncher(LauncherJson("0.9.0", "https://evil.example/x.exe", 1000, sha)) == null, "launcher url on another host refused");
            T.Ok(ParseLauncher(LauncherJson("0.9.0", "http://muffindevelopment.com/x.exe", 1000, sha)) == null, "launcher url over http refused");
            T.Ok(ParseLauncher(LauncherJson("0.9", "a.exe", 1000, sha)) == null, "two-part launcher version refused");
            T.Ok(ParseLauncher(LauncherJson("0.9.0-x", "a.exe", 1000, sha)) == null, "non-numeric launcher version refused");
            T.Ok(ParseLauncher(LauncherJson("0.9.0", "a.exe", 0, sha)) == null, "zero size refused");
            T.Ok(ParseLauncher(LauncherJson("0.9.0", "a.exe", 1000, "abc")) == null, "bad sha refused");
            T.Ok(ParseLauncher(LauncherJson("0.9.0", "", 1000, sha)) == null, "missing url refused");
            T.Ok(ParseLauncher("[]") == null && ParseLauncher("{") == null, "garbage refused");

            var live = ParseLauncher(LauncherJson("0.10.0", "a.exe", 10, sha));
            T.Eq(SelfUpdate.Decide(live, "0.9.0", false, false, true, 0), SelfUpdateAction.Apply, "newer (0.10 > 0.9, numeric) applies");
            T.Eq(SelfUpdate.Decide(live, "0.10.0", false, false, true, 0), SelfUpdateAction.None, "same version: nothing");
            T.Eq(SelfUpdate.Decide(live, "0.11.0", false, false, true, 0), SelfUpdateAction.None, "never downgrades");
            T.Eq(SelfUpdate.Decide(null, "0.9.0", false, false, true, 0), SelfUpdateAction.None, "no manifest: nothing");
            T.Eq(SelfUpdate.Decide(live, "0.9.0", true, false, true, 0), SelfUpdateAction.Wait, "game running: wait");
            T.Eq(SelfUpdate.Decide(live, "0.9.0", false, true, true, 0), SelfUpdateAction.Wait, "game downloading: wait");
            T.Eq(SelfUpdate.Decide(live, "0.9.0", false, false, false, 0), SelfUpdateAction.LinkOnly, "folder not writable: link");
            T.Eq(SelfUpdate.Decide(live, "0.9.0", false, false, true, SelfUpdate.MaxFailures), SelfUpdateAction.LinkOnly, "too many failures: link");
        }

        static async Task SelfUpdateFileTests()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "dm-selfupdate-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tmp);
            try
            {
                string exe = Path.Combine(tmp, LauncherManifest.ExeName);
                byte[] oldExe = Blob(5000, 1), newExe = Blob(7000, 2);
                File.WriteAllBytes(exe, oldExe);
                T.Ok(SelfUpdate.FolderWritable(exe), "temp folder is writable");

                using (var srv = new TestServer())
                using (var http = new HttpClient())
                {
                    srv.Files["DeathMuffinLauncher.exe"] = newExe;
                    var good = ParseLauncherAt(srv, newExe.Length, Sha(newExe));

                    // A corrupt download is refused and leaves nothing to swap.
                    srv.CorruptFirst["DeathMuffinLauncher.exe"] = 1;
                    bool threw = false;
                    try { await SelfUpdate.DownloadAsync(http, good, exe, CancellationToken.None); } catch (InvalidDataException) { threw = true; }
                    T.Ok(threw && !File.Exists(SelfUpdate.NewPath(exe)), "corrupt launcher download refused, no .new left");

                    // A manifest that understates the size is refused while downloading.
                    threw = false;
                    try { await SelfUpdate.DownloadAsync(http, ParseLauncherAt(srv, 100, Sha(newExe)), exe, CancellationToken.None); } catch (InvalidDataException) { threw = true; }
                    T.Ok(threw && !File.Exists(SelfUpdate.NewPath(exe)), "oversized launcher download refused");

                    // The good one: .new verified, then swapped in; the running exe becomes .old.
                    await SelfUpdate.DownloadAsync(http, good, exe, CancellationToken.None);
                    T.Ok(File.Exists(SelfUpdate.NewPath(exe)), "verified download lands as .new");
                    SelfUpdate.Swap(exe);
                    T.Ok(File.ReadAllBytes(exe).SequenceEqual(newExe), "new launcher in place");
                    T.Ok(File.ReadAllBytes(SelfUpdate.OldPath(exe)).SequenceEqual(oldExe), "previous launcher kept as .old");
                    T.Ok(!File.Exists(SelfUpdate.NewPath(exe)), ".new consumed by the swap");

                    // The next start cleans up after it.
                    File.WriteAllBytes(exe + ".new.part", new byte[3]);
                    SelfUpdate.CleanUp(exe);
                    T.Ok(!File.Exists(SelfUpdate.OldPath(exe)) && !File.Exists(exe + ".new.part") && File.Exists(exe), "cleanup removes .old and partials, keeps the exe");

                    // Swap with nothing downloaded throws and leaves the exe alone.
                    threw = false;
                    try { SelfUpdate.Swap(exe); } catch (FileNotFoundException) { threw = true; }
                    T.Ok(threw && File.ReadAllBytes(exe).SequenceEqual(newExe), "swap without a download changes nothing");
                }
            }
            finally { try { Directory.Delete(tmp, true); } catch (Exception) { } }
        }

        /// <summary>A launcher manifest pointing at the test server (http on loopback, so parsed against the server's own base).</summary>
        static LauncherManifest ParseLauncherAt(TestServer srv, long size, string sha)
        {
            var m = ParseLauncher(LauncherJson("9.9.9", "DeathMuffinLauncher.exe", size, sha), srv.Base + "manifest.json");
            if (m == null) throw new Exception("test launcher manifest did not parse");
            return m;
        }

        sealed class SyncProgress : IProgress<InstallProgress>
        {
            readonly Action<InstallProgress> a;
            public SyncProgress(Action<InstallProgress> a) { this.a = a; }
            public void Report(InstallProgress v) { a(v); }
        }
    }
}
