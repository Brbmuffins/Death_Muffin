using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam.Tests
{
    /// <summary>
    /// A stand-in ComfyUI server: the routes a `model` job uses, with input and output folders on disk under <see cref="Root"/>. Each queued run ends as <see cref="Outcome"/> says (by its prompt): "ok" saves a
    /// small binary glTF, "error" ends in ComfyUI's execution error, "never" never ends, "refuse" is a 400 with node errors, "badglb" saves a file that is not a model, "nosave" saves nothing.
    /// </summary>
    sealed class FakeComfy : IDisposable
    {
        readonly HttpListener l = new HttpListener();
        public readonly int Port;
        public readonly string Root;
        public long VramBytes = 12878610432L;   // a 4070 SUPER: 12,282 MiB
        public string Version = "0.22.3";
        public string Device = "cuda:0 NVIDIA GeForce RTX 4070 SUPER : cudaMallocAsync";
        public Func<Dictionary<string, object>, string> Outcome = p => "ok";
        /// <summary>How many /history polls of a run answer "not yet" before it ends.</summary>
        public int PollsBeforeDone = 2;
        public readonly List<Dictionary<string, object>> Prompts = new List<Dictionary<string, object>>();
        public readonly List<string> Uploads = new List<string>();
        public readonly List<string> Calls = new List<string>();
        readonly Dictionary<string, int> polls = new Dictionary<string, int>();
        readonly Dictionary<string, string> ends = new Dictionary<string, string>();
        readonly Dictionary<string, string> prefixes = new Dictionary<string, string>();

        public FakeComfy(int port, string root)
        {
            Port = port;
            Root = root;
            l.Prefixes.Add("http://127.0.0.1:" + port + "/");
            l.Start();
            Task.Run(Loop);
        }

        public static int FreePort()
        {
            using (var s = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0)) { s.Start(); int p = ((IPEndPoint)s.LocalEndpoint).Port; s.Stop(); return p; }
        }

        /// <summary>The run's label, from the prefix the app gave it ("dmteam/&lt;job&gt;-&lt;label&gt;").</summary>
        public static string LabelOf(Dictionary<string, object> prompt)
        {
            string prefix = MiniJson.Str(MiniJson.Obj(MiniJson.Obj(prompt, "322"), "inputs"), "filename_prefix");
            return prefix.Substring(prefix.IndexOf('-') + 1);
        }

        public static object Input(Dictionary<string, object> prompt, string node, string input) { return MiniJson.Obj(MiniJson.Obj(prompt, node), "inputs")[input]; }

        public int CallCount(string prefix) { lock (Calls) return Calls.Count(c => c.StartsWith(prefix)); }

        /// <summary>A minimal binary glTF 2.0: the header and a JSON chunk with one mesh.</summary>
        public static byte[] Glb()
        {
            byte[] json = Encoding.UTF8.GetBytes("{\"asset\":{\"version\":\"2.0\"},\"meshes\":[{\"primitives\":[]}]}");
            int pad = (4 - json.Length % 4) % 4;
            var ms = new MemoryStream();
            var w = new BinaryWriter(ms);
            w.Write(Encoding.ASCII.GetBytes("glTF")); w.Write(2u); w.Write((uint)(12 + 8 + json.Length + pad));
            w.Write((uint)(json.Length + pad)); w.Write(0x4E4F534Au); w.Write(json); for (int i = 0; i < pad; i++) w.Write((byte)' ');
            return ms.ToArray();
        }

        async Task Loop()
        {
            while (l.IsListening)
            {
                HttpListenerContext c;
                try { c = await l.GetContextAsync(); } catch (Exception) { return; }
                var ignored = Task.Run(() => Handle(c));
            }
        }

        void Reply(HttpListenerContext c, int status, object json) { Bytes(c, status, Encoding.UTF8.GetBytes(MiniJson.Write(json)), "application/json"); }

        static void Bytes(HttpListenerContext c, int status, byte[] body, string type)
        {
            c.Response.StatusCode = status;
            c.Response.ContentType = type;
            c.Response.ContentLength64 = body.Length;
            c.Response.OutputStream.Write(body, 0, body.Length);
            c.Response.Close();
        }

        void Handle(HttpListenerContext c)
        {
            try
            {
                string path = c.Request.Url.AbsolutePath;
                byte[] body;
                using (var ms = new MemoryStream()) { c.Request.InputStream.CopyTo(ms); body = ms.ToArray(); }
                if (path == "/system_stats")
                {
                    Reply(c, 200, new Dictionary<string, object>
                    {
                        { "system", new Dictionary<string, object> { { "os", "nt" }, { "comfyui_version", Version }, { "python_version", "3.12.9" } } },
                        { "devices", new List<object> { new Dictionary<string, object> { { "name", Device }, { "type", "cuda" }, { "index", 0.0 }, { "vram_total", (double)VramBytes }, { "vram_free", (double)VramBytes / 2 } } } },
                    });
                    return;
                }
                if (path == "/upload/image") { Upload(c, body); return; }
                if (path == "/prompt") { Queue(c, body); return; }
                if (path.StartsWith("/history/")) { History(c, Uri.UnescapeDataString(path.Substring(9))); return; }
                if (path == "/view")
                {
                    string file = Path.Combine(Root, c.Request.QueryString["type"] ?? "output", c.Request.QueryString["subfolder"] ?? "", c.Request.QueryString["filename"] ?? "");
                    if (!File.Exists(file)) { Reply(c, 404, new Dictionary<string, object>()); return; }
                    Bytes(c, 200, File.ReadAllBytes(file), "model/gltf-binary");
                    return;
                }
                if (path == "/queue" || path == "/interrupt" || path == "/free")
                {
                    lock (Calls) Calls.Add(path.TrimStart('/') + " " + Encoding.UTF8.GetString(body));
                    Reply(c, 200, new Dictionary<string, object>());
                    return;
                }
                Reply(c, 404, new Dictionary<string, object>());
            }
            catch (Exception) { try { c.Response.Abort(); } catch (Exception) { } }
        }

        void Upload(HttpListenerContext c, byte[] body)
        {
            // multipart/form-data: the text fields, then the file
            string type = c.Request.ContentType ?? "";
            string boundary = "--" + type.Substring(type.IndexOf("boundary=") + 9);
            string text = Encoding.GetEncoding("ISO-8859-1").GetString(body);
            var fields = new Dictionary<string, string>();
            string fileName = null;
            byte[] data = null;
            foreach (string part in text.Split(new[] { boundary }, StringSplitOptions.None))
            {
                int split = part.IndexOf("\r\n\r\n");
                if (split < 0) continue;
                string head = part.Substring(0, split), value = part.Substring(split + 4);
                if (value.EndsWith("\r\n")) value = value.Substring(0, value.Length - 2);
                string name = Between(head, "name=\"", "\"");
                if (head.Contains("filename=\"")) { fileName = Between(head, "filename=\"", "\""); data = Encoding.GetEncoding("ISO-8859-1").GetBytes(value); }
                else if (name != null) fields[name] = value;
            }
            string sub = fields.ContainsKey("subfolder") ? fields["subfolder"] : "";
            lock (Uploads) Uploads.Add(sub + "/" + fileName + " " + (fields.ContainsKey("type") ? fields["type"] : "") + " overwrite=" + (fields.ContainsKey("overwrite") ? fields["overwrite"] : ""));
            string dir = Path.Combine(Root, "input", sub);
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, fileName), data);
            Reply(c, 200, new Dictionary<string, object> { { "name", fileName }, { "subfolder", sub }, { "type", "input" } });
        }

        static string Between(string s, string a, string b)
        {
            int i = s.IndexOf(a);
            if (i < 0) return null;
            i += a.Length;
            int j = s.IndexOf(b, i);
            return j < 0 ? null : s.Substring(i, j - i);
        }

        void Queue(HttpListenerContext c, byte[] body)
        {
            var d = MiniJson.TryObject(Encoding.UTF8.GetString(body));
            var prompt = MiniJson.Obj(d, "prompt");
            lock (Prompts) Prompts.Add(prompt);
            string end = Outcome(prompt);
            if (end == "refuse")
            {
                Reply(c, 400, new Dictionary<string, object>
                {
                    { "error", new Dictionary<string, object> { { "type", "prompt_outputs_failed_validation" }, { "message", "Prompt outputs failed validation" }, { "details", "" } } },
                    { "node_errors", new Dictionary<string, object> { { "186", new Dictionary<string, object> {
                        { "errors", new List<object> { new Dictionary<string, object> { { "type", "value_bigger_than_max" }, { "message", "Value 900000 bigger than max of 500000" }, { "details", "target_face_count" } } } },
                        { "class_type", "DecimateMesh" } } } } },
                });
                return;
            }
            string id = Guid.NewGuid().ToString();
            lock (ends) { ends[id] = end; polls[id] = 0; prefixes[id] = MiniJson.Str(MiniJson.Obj(MiniJson.Obj(prompt, "322"), "inputs"), "filename_prefix"); }
            Reply(c, 200, new Dictionary<string, object> { { "prompt_id", id }, { "number", 1.0 }, { "node_errors", new Dictionary<string, object>() } });
        }

        void History(HttpListenerContext c, string id)
        {
            string end, prefix;
            int n;
            lock (ends)
            {
                if (!ends.TryGetValue(id, out end)) { Reply(c, 200, new Dictionary<string, object>()); return; }
                n = ++polls[id];
                prefix = prefixes[id];
            }
            if (end == "never" || n <= PollsBeforeDone) { Reply(c, 200, new Dictionary<string, object>()); return; }
            var entry = new Dictionary<string, object> { { "prompt", new List<object>() }, { "meta", new Dictionary<string, object>() } };
            if (end == "error")
            {
                entry["outputs"] = new Dictionary<string, object>();
                entry["status"] = new Dictionary<string, object> { { "status_str", "error" }, { "completed", false }, { "messages", new List<object> {
                    new List<object> { "execution_start", new Dictionary<string, object> { { "prompt_id", id } } },
                    new List<object> { "execution_error", new Dictionary<string, object> { { "prompt_id", id }, { "node_id", "147" }, { "node_type", "BakeTextureFromVoxel" },
                        { "exception_message", "CUDA out of memory. Tried to allocate 2.00 GiB" }, { "exception_type", "torch.OutOfMemoryError" } } } } } };
            }
            else
            {
                var outputs = new Dictionary<string, object>();
                if (end != "nosave")
                {
                    string sub = prefix.Contains("/") ? prefix.Substring(0, prefix.LastIndexOf('/')) : "", name = prefix.Substring(prefix.LastIndexOf('/') + 1) + "_00001_.glb";
                    string dir = Path.Combine(Root, "output", sub);
                    Directory.CreateDirectory(dir);
                    File.WriteAllBytes(Path.Combine(dir, name), end == "badglb" ? Encoding.UTF8.GetBytes("this is not a model at all") : Glb());
                    outputs["322"] = new Dictionary<string, object> { { "3d", new List<object> { new Dictionary<string, object> { { "filename", name }, { "subfolder", sub }, { "type", "output" } } } } };
                }
                entry["outputs"] = outputs;
                entry["status"] = new Dictionary<string, object> { { "status_str", "success" }, { "completed", true }, { "messages", new List<object>() } };
            }
            Reply(c, 200, new Dictionary<string, object> { { id, entry } });
        }

        public void Dispose()
        {
            try { l.Stop(); l.Close(); } catch (Exception) { }
        }
    }

    /// <summary>The app's own ComfyUI server as a test sees it: "serve" starts a stand-in server on the port the app chose, "exit" ends at once with some output, "silent" runs and never answers.</summary>
    sealed class FakeComfyLauncher : IComfyLauncher
    {
        public readonly List<ComfyLaunch> Starts = new List<ComfyLaunch>();
        public string Mode = "serve";
        /// <summary>How the server it starts ends each run (FakeComfy.Outcome).</summary>
        public Func<Dictionary<string, object>, string> Outcome = p => "ok";
        public FakeComfy Server;
        public ServerProcess Proc;

        public IGameProcess Start(ComfyLaunch launch)
        {
            Starts.Add(launch);
            int port = int.Parse(launch.Args[launch.Args.IndexOf("--port") + 1]);
            string root = Path.GetDirectoryName(launch.Args[launch.Args.IndexOf("--output-directory") + 1]);
            Proc = new ServerProcess();
            if (Mode == "exit") { Proc.Exited = true; Proc.Code = 1; Proc.Text = "Traceback (most recent call last):\nModuleNotFoundError: No module named 'comfy_aimdo'"; return Proc; }
            if (Mode == "serve")
            {
                Server = new FakeComfy(port, root) { Outcome = Outcome };
                Proc.Server = Server;
            }
            return Proc;
        }

        public sealed class ServerProcess : IGameProcess
        {
            public volatile bool Exited, Killed;
            public int Code;
            public string Text = "";
            public FakeComfy Server;
            public int Id { get { return 4242; } }
            public bool HasExited { get { return Exited; } }
            public int ExitCode { get { return Code; } }
            public void Kill() { Killed = true; Exited = true; if (Server != null) Server.Dispose(); }
            public void Tend() { }
            public string Output() { return Text; }
            public void Dispose() { }
        }
    }

    /// <summary>A ComfyUI Desktop install on disk, as ComfyInstall.Find reads it: %APPDATA%\ComfyUI\config.json, the ComfyUI folder with its .venv, and Desktop's program files.</summary>
    sealed class FakeDesktop : IDisposable
    {
        public readonly string Top = Util.TempDir("comfy");
        public string AppData { get { return Path.Combine(Top, "Roaming"); } }
        public string Local { get { return Path.Combine(Top, "Local"); } }
        public string Base { get { return Path.Combine(Top, "Documents", "ComfyUI"); } }

        public FakeDesktop(string appFolder = "ComfyUI", bool frontEnd = true, bool extraModels = true)
        {
            Directory.CreateDirectory(Path.Combine(AppData, "ComfyUI"));
            File.WriteAllText(Path.Combine(AppData, "ComfyUI", "config.json"), MiniJson.Write(new Dictionary<string, object> { { "basePath", Base }, { "installState", "installed" } }));
            if (extraModels) File.WriteAllText(Path.Combine(AppData, "ComfyUI", "extra_models_config.yaml"), "comfyui:\n  base_path: x\n");
            Directory.CreateDirectory(Path.Combine(Base, ".venv", "Scripts"));
            File.WriteAllText(Path.Combine(Base, ".venv", "Scripts", "python.exe"), "");
            string comfy = Path.Combine(Local, "Programs", appFolder, "resources", "ComfyUI");
            Directory.CreateDirectory(comfy);
            File.WriteAllText(Path.Combine(comfy, "main.py"), "");
            if (frontEnd) Directory.CreateDirectory(Path.Combine(comfy, "web_custom_versions", "desktop_app"));
        }

        public ComfyInstall Find(out string why) { return ComfyInstall.Find(AppData, Local, out why); }

        public void Dispose() { Util.Rm(Top); }
    }

    /// <summary>A runner rig with ComfyUI: the stand-in Desktop install, a Desktop server (when <see cref="StartDesktop"/> is called) and the launcher for the app's own.</summary>
    sealed class ModelRig : IDisposable
    {
        public readonly Rig R = new Rig();
        public readonly FakeDesktop Desktop = new FakeDesktop();
        public readonly FakeComfyLauncher Launcher = new FakeComfyLauncher();
        public readonly int DesktopPort = FakeComfy.FreePort(), OwnPort = FakeComfy.FreePort();
        public readonly string OwnRoot;
        public readonly ComfyHost Host;
        public FakeComfy DesktopServer;
        public bool Installed = true;
        int n;

        public ModelRig()
        {
            OwnRoot = Path.Combine(R.Root, "comfy");
            Host = new ComfyHost(new HttpComfyHttp(), Launcher, (out string why) => { why = "ComfyUI Desktop is not set up on this PC (no config.json)"; return Installed ? Desktop.Find(out why) : null; }, OwnRoot)
            {
                DesktopPort = DesktopPort, OwnPortFirst = OwnPort - 1, OwnPortLast = OwnPort, PortFree = p => p == OwnPort,
                PollMs = 10, StartLimit = TimeSpan.FromSeconds(3), IdleStop = TimeSpan.FromMilliseconds(300),
            };
            R.Runner.Comfy = Host;
            R.Runner.ComfyPollMs = 5;
        }

        public FakeComfy StartDesktop() { return DesktopServer = new FakeComfy(DesktopPort, Desktop.Base); }

        public static Dictionary<string, object> Run(string label, string image = "concept.png", string model = "pixal3d", int faces = 5000, int texture = 1024, long? seed = null)
        {
            var d = new Dictionary<string, object> { { "label", label }, { "image", image }, { "model", model }, { "faces", (double)faces }, { "texture", (double)texture } };
            if (seed != null) d["seed"] = (double)seed.Value;
            return d;
        }

        /// <summary>A `model` payload: one picture on the test server and the runs given (default: the hound with Pixal3D and with TRELLIS.2).</summary>
        public JobPlan Plan(params Dictionary<string, object>[] runs)
        {
            string folder = "model" + (++n) + "x";
            var p = new Dictionary<string, object>
            {
                { "files", new List<object> { R.Srv.Publish(folder, "concept.png", Util.FakePng(70 + n)) } },
                { "runs", (runs.Length > 0 ? runs : new[] { Run("hound-pixal3d"), Run("hound-trellis2", model: "trellis2", seed: 7) }).Cast<object>().ToList() },
            };
            JobPlan plan; string err;
            if (!JobPlan.TryParse(JobPlan.ModelKind, p, R.Srv.SiteBase, out plan, out err)) throw new InvalidOperationException("test model payload refused: " + err);
            return plan;
        }

        public void Dispose()
        {
            Host.Dispose();
            if (DesktopServer != null) DesktopServer.Dispose();
            if (Launcher.Server != null) Launcher.Server.Dispose();
            Desktop.Dispose();
            R.Dispose();
        }
    }

    static class ModelTests
    {
        static readonly Uri Site = new Uri("https://muffindevelopment.com/death-muffin/");

        public static void Run()
        {
            Workflow();
            Plans();
            ClientText();
            Install();
            DesktopServerRuns();
            SmallCard();
            OwnServer();
            OwnServerFails();
            NotInstalled();
            SomeRunsFail();
            StoppedRuns();
            Helpers();
        }

        static Dictionary<string, object> Payload(Action<Dictionary<string, object>> mutate = null)
        {
            var p = new Dictionary<string, object>
            {
                { "files", new List<object> { Program.File_("concept.png"), Program.File_("side.jpg") } },
                { "runs", new List<object> { ModelRig.Run("hound-pixal3d"), ModelRig.Run("hound-side", image: "side.jpg", model: "trellis2", faces: 20000, texture: 2048, seed: 3) } },
            };
            if (mutate != null) mutate(p);
            return p;
        }

        static string Refused(Action<Dictionary<string, object>> mutate)
        {
            JobPlan plan; string error;
            return JobPlan.TryParse(JobPlan.ModelKind, Payload(mutate), Site, out plan, out error) ? null : error;
        }

        /// <summary>The workflow file as the app holds it (built in: teamapp/comfy/image-to-model.json).</summary>
        static string WorkflowText()
        {
            using (Stream st = typeof(ComfyWorkflow).Assembly.GetManifestResourceStream(ComfyWorkflow.ResourceName))
            using (var r = new StreamReader(st)) return r.ReadToEnd();
        }

        static void Workflow()
        {
            string error;
            ComfyWorkflow w = ComfyWorkflow.Embedded(out error);
            T.Ok(w != null && error == null, "the workflow built into the app reads (" + error + ")");
            if (w == null) return;
            T.Eq(w.SaveNode, "322", "the workflow's save node");
            T.Has(w.About, "make-workflow.py", "the workflow says where it came from");
            var a = w.Fill(new ModelRun { Label = "a", Image = "concept.png", Model = ComfyRules.Trellis2, Faces = 5000, Texture = 1024, Seed = 7 }, "dmteam/job1-concept.png", "dmteam/job1-a");
            T.Eq(FakeComfy.Input(a, "122", "image"), (object)"dmteam/job1-concept.png", "the picture goes in LoadImage");
            T.Eq(FakeComfy.Input(a, "316", "value"), (object)true, "trellis2 flips the template's switch");
            T.Eq(FakeComfy.Input(a, "186", "target_face_count"), (object)5000L, "the face count goes in DecimateMesh, before the paint (no shrinking afterwards)");
            T.Ok(Equals(FakeComfy.Input(a, "288", "value"), 1024L) && Equals(FakeComfy.Input(a, "224", "resolution"), 1024L), "the texture size goes in the colour bake and the normal map");
            T.Eq(FakeComfy.Input(a, "322", "filename_prefix"), (object)"dmteam/job1-a", "the model is saved under the app's folder");
            string json = MiniJson.Write(a);
            var original = MiniJson.TryObject(WorkflowText());
            var seeds = MiniJson.Obj(original, "seedBase");
            bool seedsAdded = seeds != null && seeds.Count > 0;
            if (seeds != null) foreach (var kv in seeds) seedsAdded &= Equals(FakeComfy.Input(a, kv.Key, "seed"), (long)(double)kv.Value + 7);
            T.Ok(seedsAdded, "a run's seed is added to each of the template's seeds");
            var b = w.Fill(new ModelRun { Label = "b", Image = "x.png", Model = ComfyRules.Pixal3d, Faces = 800, Texture = 512, Seed = 0 }, "dmteam/x.png", "dmteam/job1-b");
            T.Eq(FakeComfy.Input(b, "316", "value"), (object)false, "pixal3d leaves the switch off");
            T.Eq(FakeComfy.Input(b, "186", "target_face_count"), (object)800L, "a second fill has its own face count");
            T.Eq(MiniJson.Write(a), json, "filling a run never changes another run's nodes");
            if (seeds != null) foreach (var kv in seeds) T.Eq(FakeComfy.Input(b, kv.Key, "seed"), (object)(long)(double)kv.Value, "seed 0 keeps the template's seed " + kv.Key);

            // a broken workflow file is refused with a reason, never half-filled on a PC
            Func<Action<Dictionary<string, object>>, string> broken = mutate =>
            {
                var d = MiniJson.TryObject(WorkflowText());
                mutate(d);
                string e;
                return ComfyWorkflow.Parse(MiniJson.Write(d), out e) == null ? e : null;
            };
            if (original != null)
            {
                T.Has(broken(d => MiniJson.Obj(d, "slots").Remove("faces")), "faces", "a workflow without a faces slot is refused");
                T.Has(broken(d => MiniJson.Obj(d, "slots")["image"] = new List<object> { new List<object> { "999", "image" } }), "image slot", "a slot that names a missing node is refused");
                T.Has(broken(d => MiniJson.Obj(d, "slots")["faces"] = new List<object> { new List<object> { "186", "mesh" } }), "faces slot", "a slot that names a link, not a value, is refused");
                T.Has(broken(d => MiniJson.Obj(d, "seedBase").Remove("12")), "base seed", "a seed slot without its base is refused");
                T.Has(broken(d => d["save"] = "999"), "save node", "a save node that is not there is refused");
            }
            else T.Ok(false, "the workflow is built into the tests too");
            T.Ok(ComfyWorkflow.Parse("{}", out error) == null && error.Length > 0, "an empty workflow is refused");
        }

        static void Plans()
        {
            JobPlan plan; string error;
            T.Ok(JobPlan.RunsKind(JobPlan.ModelKind), "this version runs model jobs");
            T.Ok(JobPlan.TryParse(JobPlan.ModelKind, Payload(), Site, out plan, out error), "a model payload parses (" + error + ")");
            if (plan != null)
            {
                T.Eq(plan.ModelRuns.Count, 2, "both runs are read");
                ModelRun a = plan.ModelRuns[0], b = plan.ModelRuns[1];
                T.Eq(a.Label + "|" + a.Image + "|" + a.Model + "|" + a.Faces + "|" + a.Texture + "|" + a.Seed, "hound-pixal3d|concept.png|pixal3d|5000|1024|0", "a run without a seed has seed 0");
                T.Eq(b.Label + "|" + b.Image + "|" + b.Model + "|" + b.Faces + "|" + b.Texture + "|" + b.Seed, "hound-side|side.jpg|trellis2|20000|2048|3", "a run with every field");
                T.Eq(plan.Args.Count, 0, "a model job adds no game options");
                T.Eq(a.Describe(), "pixal3d, 5000 faces, texture 1024, seed 0", "a run's words for the log");
            }
            T.Has(Refused(p => p.Remove("runs")), "no model runs", "a model job needs runs");
            T.Has(Refused(p => p["runs"] = Enumerable.Range(0, ComfyRules.MaxRuns + 1).Select(i => (object)ModelRig.Run("r" + i)).ToList()), "too many model runs", "a model job has at most " + ComfyRules.MaxRuns + " runs");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("Hound!") }), "label that is not allowed", "a run's label is a file name's");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a"), ModelRig.Run("a") }), "twice", "two runs cannot share a label");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a", image: "other.png") }), "does not include", "a run's picture is one of the job's files");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a", model: "hunyuan") }), "pixal3d or trellis2", "only the two models are known");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a", faces: ComfyRules.FacesMin - 1) }), "face count", "too few faces are refused");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a", faces: ComfyRules.FacesMax + 1) }), "face count", "too many faces are refused");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a", texture: 1000) }), "texture size", "a texture size the bake does not take is refused");
            T.Has(Refused(p => p["runs"] = new List<object> { ModelRig.Run("a", seed: -1) }), "seed", "a negative seed is refused");
            T.Has(Refused(p => p["files"] = new List<object> { Program.File_("concept.png"), Program.File_("notes.txt") }), "pictures only", "a model job's files are pictures");
            T.Has(Refused(p => p["files"] = new List<object> { Program.File_("concept.png", bytes: (double)(JobPlan.MaxModelImageBytes + 1)) }), "too big", "a picture over the limit is refused");
            T.Has(Refused(p => p["files"] = new List<object> { Program.File_("concept.png", cacheKey: "art-1") }), "cache", "a model job's pictures are not cached");
            T.Has(Refused(p => p["args"] = new List<object> { "--qa" }), "no game options", "a model job takes no game options");
            T.Eq(TeamLogic.DefaultTitle(JobPlan.ModelKind), "3D models from a picture", "the box's words for a model job");
            T.Has(TeamLogic.OfferNote(JobPlan.ModelKind), "ComfyUI", "the box says ComfyUI makes the models");
        }

        static void ClientText()
        {
            var refusal = MiniJson.TryObject("{\"error\":{\"type\":\"prompt_outputs_failed_validation\",\"message\":\"Prompt outputs failed validation\",\"details\":\"\"},\"node_errors\":{\"186\":{\"errors\":[{\"type\":\"value_bigger_than_max\",\"message\":\"Value 900000 bigger than max of 500000\",\"details\":\"target_face_count\"}],\"class_type\":\"DecimateMesh\"}}}");
            T.Eq(ComfyClient.Refusal(refusal), "Prompt outputs failed validation; DecimateMesh: Value 900000 bigger than max of 500000: target_face_count", "a refusal names the node and ComfyUI's reason");
            var missing = MiniJson.TryObject("{\"error\":{\"type\":\"missing_node_type\",\"message\":\"Node 'PixalSampler' not found. The custom node may not be installed.\",\"details\":\"Node ID '#18'\"},\"node_errors\":{}}");
            T.Has(ComfyClient.Refusal(missing), "may not be installed (Node ID '#18')", "a missing node is said in ComfyUI's words");
            var messages = (List<object>)MiniJson.Parse("[[\"execution_start\",{}],[\"execution_error\",{\"node_type\":\"KSampler\",\"exception_message\":\"CUDA out of memory\",\"exception_type\":\"torch.OutOfMemoryError\"}]]");
            T.Eq(ComfyClient.RunError(messages), "ComfyUI stopped at KSampler: CUDA out of memory", "a failed run names the node and the error");
            T.Has(ComfyClient.RunError((List<object>)MiniJson.Parse("[[\"execution_interrupted\",{}]]")), "interrupted", "an interrupted run says so");
            T.Has(ComfyClient.RunError(null), "no reason", "a failed run without messages still has words");
            byte[] mp = ComfyClient.Multipart("BND", new Dictionary<string, string> { { "subfolder", "dmteam" } }, "image", "a.png", new byte[] { 1, 2, 3 });
            string text = Encoding.GetEncoding("ISO-8859-1").GetString(mp);
            T.Ok(text.StartsWith("--BND\r\nContent-Disposition: form-data; name=\"subfolder\"\r\n\r\ndmteam\r\n--BND\r\n") && text.Contains("filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n\u0001\u0002\u0003\r\n--BND--\r\n"), "the upload is a plain multipart form");
        }

        static void Install()
        {
            using (var d = new FakeDesktop())
            {
                string why;
                ComfyInstall i = d.Find(out why);
                T.Ok(i != null && why == null, "a Desktop install is found (" + why + ")");
                if (i == null) return;
                T.Eq(i.Python, Path.Combine(d.Base, ".venv", "Scripts", "python.exe"), "Desktop's own Python");
                T.Eq(i.MainPy, Path.Combine(d.Local, "Programs", "ComfyUI", "resources", "ComfyUI", "main.py"), "the ComfyUI Desktop bundles");
                T.Ok(i.FrontEnd.EndsWith("desktop_app") && i.ExtraModels.EndsWith("extra_models_config.yaml"), "its web page and extra model folders");
                ComfyLaunch l = ComfyHost.LaunchFor(i, "/team/comfy", 8191);
                string args = string.Join(" ", l.Args);
                T.Ok(l.Args[0] == i.MainPy && args.Contains("--base-directory " + d.Base) && args.Contains("--listen 127.0.0.1 --port 8191"), "the server starts from Desktop's files, on this PC only (" + args + ")");
                T.Ok(args.Contains("--output-directory " + Path.Combine("/team/comfy", "output")) && args.Contains("--input-directory " + Path.Combine("/team/comfy", "input")) && args.Contains("--user-directory " + Path.Combine("/team/comfy", "user")), "with the app's own folders, not the member's");
                T.Ok(args.Contains("--extra-model-paths-config " + i.ExtraModels) && args.Contains("--front-end-root " + i.FrontEnd), "and Desktop's extra model folders and web page");
                T.Ok(l.Env["PYTHONIOENCODING"] == "utf-8" && l.Env["VIRTUAL_ENV"] == Path.Combine(d.Base, ".venv") && l.Env["PATH"].StartsWith(Path.Combine(d.Base, ".venv", "Scripts")), "in Desktop's virtual environment, UTF-8 out");
                T.Eq(l.WorkingDir, d.Base, "from the ComfyUI folder");
            }
            using (var d = new FakeDesktop("@comfyorgcomfyui-electron", frontEnd: false, extraModels: false))
            {
                string why;
                ComfyInstall i = d.Find(out why);
                T.Ok(i != null && i.MainPy.Contains("@comfyorgcomfyui-electron"), "Desktop's other program folder name is found too");
                string args = i == null ? "" : string.Join(" ", ComfyHost.LaunchFor(i, "/t", 8190).Args);
                T.Ok(i != null && !args.Contains("--front-end-root") && !args.Contains("--extra-model-paths-config"), "the optional parts are left out when they are not there");
            }
            using (var d = new FakeDesktop())
            {
                string why;
                File.Delete(Path.Combine(d.Base, ".venv", "Scripts", "python.exe"));
                T.Ok(d.Find(out why) == null && why.Contains("Python"), "no Python: not found, with the reason");
                File.Delete(Path.Combine(d.AppData, "ComfyUI", "config.json"));
                T.Ok(d.Find(out why) == null && why.Contains("not set up"), "no settings: not found, with the reason");
            }
            using (var d = new FakeDesktop())
            {
                string why;
                Directory.Delete(Path.Combine(d.Local, "Programs"), true);
                T.Ok(d.Find(out why) == null && why.Contains("program files"), "no program files: not found, with the reason");
            }
        }

        static void DesktopServerRuns()
        {
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                var progress = new List<string>();
                RunResult r = m.R.Run("modeljob1", m.Plan(), progress);
                T.Ok(r.Ok, "a model job on Desktop's server is done (" + r.Error + ")");
                T.Eq(string.Join(",", m.R.Api.DoneFiles ?? new List<string>()), "hound-pixal3d.glb,hound-trellis2.glb", "done names each run's model");
                T.Ok(m.R.Api.UploadedBytes.ContainsKey("hound-pixal3d.glb") && m.R.Api.UploadedBytes["hound-pixal3d.glb"].SequenceEqual(FakeComfy.Glb()), "the model is uploaded as ComfyUI made it");
                T.Eq(m.Launcher.Starts.Count, 0, "Desktop's server is used: nothing is started");
                T.Eq(desk.Uploads.Count, 1, "the picture both runs use is put in ComfyUI once");
                T.Eq(desk.Uploads.FirstOrDefault(), "dmteam/modeljob1-concept.png input overwrite=true", "into the app's folder of ComfyUI's input, named after the job");
                T.Eq(desk.Prompts.Count, 2, "one run each");
                if (desk.Prompts.Count == 2)
                {
                    T.Ok(Equals(FakeComfy.Input(desk.Prompts[0], "316", "value"), false) && Equals(FakeComfy.Input(desk.Prompts[1], "316", "value"), true), "Pixal3D, then TRELLIS.2");
                    T.Eq(FakeComfy.Input(desk.Prompts[0], "122", "image"), (object)"dmteam/modeljob1-concept.png", "each run reads the uploaded picture");
                    T.Eq(FakeComfy.Input(desk.Prompts[1], "322", "filename_prefix"), (object)"dmteam/modeljob1-hound-trellis2", "each run saves under its own name");
                }
                T.Eq(desk.CallCount("free"), 1, "the card's memory is let go after the job");
                T.Ok(!Directory.Exists(Path.Combine(m.Desktop.Base, "input", "dmteam")) || Directory.GetFiles(Path.Combine(m.Desktop.Base, "input", "dmteam")).Length == 0, "the job's picture is removed from ComfyUI's input");
                T.Ok(!Directory.Exists(Path.Combine(m.Desktop.Base, "output", "dmteam")) || Directory.GetFiles(Path.Combine(m.Desktop.Base, "output", "dmteam")).Length == 0, "and its models from ComfyUI's output");
                T.Has(r.Log, "already running", "the log says Desktop's server was used");
                T.Has(r.Log, "RTX 4070 SUPER : cudaMallocAsync (12.0 GB)", "and which card it runs on");
                T.Ok(progress.Contains("Making 3D model 1 of 2 (hound-pixal3d)") && progress.Contains("Making 3D model 2 of 2 (hound-trellis2)"), "the tray says which model is being made");
                T.Has(r.Log, "run hound-trellis2: trellis2, 5000 faces, texture 1024, seed 7", "the log has each run's settings");

                // a file the member keeps in the same folder, not this job's, stays
                string theirs = Path.Combine(m.Desktop.Base, "output", "dmteam", "mine.glb");
                File.WriteAllText(theirs, "x");
                RunResult again = m.R.Run("modeljob2", m.Plan(ModelRig.Run("brazier", faces: 3000)));
                T.Ok(again.Ok && File.Exists(theirs), "only the job's own files are removed from ComfyUI's folders");
                T.Eq(desk.Uploads.LastOrDefault(), "dmteam/modeljob2-concept.png input overwrite=true", "a second job's picture is its own");
            }
        }

        static void SmallCard()
        {
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                desk.VramBytes = 11L * 1024 * 1024 * 1024;   // an 11 GB card
                RunResult r = m.R.Run("modeljob3", m.Plan());
                T.Ok(!r.Ok && r.Error.Contains("12 GB or more") && r.Error.Contains("11.0 GB"), "a card under 12 GB runs no model (" + r.Error + ")");
                T.Eq(desk.Prompts.Count, 0, "nothing is queued in ComfyUI");
                T.Eq(m.R.Api.FailError, r.Error, "the server is told why");
                T.Ok(ComfyRules.CardFits(12282) && ComfyRules.CardFits(16376) && !ComfyRules.CardFits(11264) && !ComfyRules.CardFits(8192) && !ComfyRules.CardFits(0), "12 GB and up fit; 11 GB and less, or unknown, do not");
            }
        }

        static void OwnServer()
        {
            using (var m = new ModelRig())
            {
                var progress = new List<string>();
                RunResult r = m.R.Run("modeljob4", m.Plan(ModelRig.Run("hound")), progress);
                T.Ok(r.Ok, "with no ComfyUI running, the app starts its own and the job is done (" + r.Error + ")");
                T.Eq(m.Launcher.Starts.Count, 1, "one server is started");
                ComfyLaunch l = m.Launcher.Starts.FirstOrDefault();
                T.Ok(l != null && l.Args.Contains("--port") && l.Args[l.Args.IndexOf("--port") + 1] == m.OwnPort.ToString(), "on the first free port of the app's range");
                T.Ok(l != null && l.Args[l.Args.IndexOf("--base-directory") + 1] == m.Desktop.Base, "with the member's ComfyUI folder (models, custom nodes)");
                T.Ok(progress.Contains("Starting ComfyUI"), "the tray says ComfyUI is starting");
                T.Has(r.Log, "answered after", "the log says when it answered");
                T.Eq(m.Launcher.Server.CallCount("free"), 1, "the card's memory is let go after the job");
                T.Ok(Directory.GetFiles(Path.Combine(m.OwnRoot, "output", "dmteam")).Length == 0 && Directory.GetFiles(Path.Combine(m.OwnRoot, "input", "dmteam")).Length == 0, "the job's files are removed from the app's own ComfyUI folders");
                T.Ok(m.Host.OwnRunning, "the server stays up a while for the next job");

                RunResult second = m.R.Run("modeljob5", m.Plan(ModelRig.Run("hound")));
                T.Ok(second.Ok && m.Launcher.Starts.Count == 1, "a job soon after uses the same server");
                T.Has(second.Log, "still running", "the log says so");

                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (m.Host.OwnRunning && clock.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(20);
                T.Ok(!m.Host.OwnRunning && m.Launcher.Proc.Killed, "it is stopped once no job came for a while");
                T.Has(m.Host.LastStop, "no job for", "because it was idle");

                RunResult third = m.R.Run("modeljob6", m.Plan(ModelRig.Run("hound")));
                T.Ok(third.Ok && m.Launcher.Starts.Count == 2, "the next job starts it again");
                m.Host.Dispose();
                T.Ok(m.Launcher.Proc.Killed && !m.Host.OwnRunning, "closing the app stops the app's own server");
                RunResult closed = m.R.Run("modeljob7", m.Plan(ModelRig.Run("hound")));
                T.Ok(!closed.Ok && closed.Error.Contains("closed"), "no server is started once the app is closing");
            }
            using (var m = new ModelRig())
            {
                m.Host.PortFree = p => false;
                RunResult r = m.R.Run("modeljob8", m.Plan(ModelRig.Run("hound")));
                T.Ok(!r.Ok && r.Error.Contains("all taken"), "every port taken: a plain failure (" + r.Error + ")");
            }
        }

        static void OwnServerFails()
        {
            using (var m = new ModelRig())
            {
                m.Launcher.Mode = "exit";
                RunResult r = m.R.Run("modeljob9", m.Plan(ModelRig.Run("hound")));
                T.Ok(!r.Ok && r.Error.Contains("stopped while it was starting") && r.Error.Contains("exit code 1"), "a server that ends while it starts fails the job (" + r.Error + ")");
                T.Has(r.Log, "No module named 'comfy_aimdo'", "with the end of what it said in the log");
            }
            using (var m = new ModelRig())
            {
                m.Launcher.Mode = "silent";
                m.Host.StartLimit = TimeSpan.FromMilliseconds(300);
                RunResult r = m.R.Run("modeljob10", m.Plan(ModelRig.Run("hound")));
                T.Ok(!r.Ok && r.Error.Contains("did not answer"), "a server that never answers is given up on (" + r.Error + ")");
                T.Ok(m.Launcher.Proc.Killed && !m.Host.OwnRunning, "and stopped");
            }
        }

        static void NotInstalled()
        {
            using (var m = new ModelRig())
            {
                m.Installed = false;
                RunResult r = m.R.Run("modeljob11", m.Plan(ModelRig.Run("hound")));
                T.Ok(!r.Ok && r.Error.StartsWith("ComfyUI is not running and could not be started: ComfyUI Desktop is not set up"), "no Desktop and nothing running: the job fails with the reason (" + r.Error + ")");
                T.Eq(m.Launcher.Starts.Count, 0, "nothing is started");
                T.Ok(!m.Host.Installed, "the host says it is not installed");
            }
            using (var m = new ModelRig())
            {
                m.R.Runner.Comfy = null;
                RunResult r = m.R.Run("modeljob12", m.Plan(ModelRig.Run("hound")));
                T.Ok(!r.Ok && r.Error.Contains("does not run model jobs"), "a runner without ComfyUI refuses model jobs");
            }
        }

        static void SomeRunsFail()
        {
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                desk.Outcome = p => FakeComfy.LabelOf(p) == "b" ? "error" : FakeComfy.LabelOf(p) == "c" ? "badglb" : FakeComfy.LabelOf(p) == "d" ? "nosave" : FakeComfy.LabelOf(p) == "e" ? "refuse" : "ok";
                RunResult r = m.R.Run("modeljob13", m.Plan(ModelRig.Run("a"), ModelRig.Run("b"), ModelRig.Run("c"), ModelRig.Run("d"), ModelRig.Run("e")));
                T.Ok(r.Ok, "a job whose other runs failed is done with the model that was made (" + r.Error + ")");
                T.Eq(string.Join(",", m.R.Api.DoneFiles ?? new List<string>()), "a.glb", "only the made model is sent");
                T.Has(r.Log, "run b FAILED: ComfyUI stopped at BakeTextureFromVoxel: CUDA out of memory", "a run ComfyUI failed is in the log with its reason");
                T.Has(r.Log, "run c FAILED: ComfyUI's model", "a file that is not a model is caught here");
                T.Has(r.Log, "run d FAILED: ComfyUI finished the run but saved no model", "a run that saved nothing is caught");
                T.Has(r.Log, "run e FAILED: ComfyUI refused the model workflow: Prompt outputs failed validation; DecimateMesh: Value 900000", "a refused run has ComfyUI's reasons");
                T.Has(r.Log, "4 run(s) made no model: b, c, d, e", "the log sums up what failed");
            }
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                desk.Outcome = p => "error";
                RunResult r = m.R.Run("modeljob14", m.Plan());
                T.Ok(!r.Ok && r.Error.Contains("None of the 2 runs made a model"), "a job with no model fails (" + r.Error + ")");
                T.Has(m.R.Api.FailLog, "CUDA out of memory", "and the server gets the reasons in the log");
                T.Eq(desk.CallCount("free"), 1, "the card's memory is let go after a failed job too");
            }
        }

        static void StoppedRuns()
        {
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                desk.Outcome = p => "never";
                var t = Task.Run(() => m.R.Run("modeljob15", m.Plan(ModelRig.Run("a"), ModelRig.Run("b"))));
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (desk.Prompts.Count == 0 && clock.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(10);
                m.R.Watch.Started = true;
                RunResult r = Util.Wait(t);
                T.Ok(!r.Ok && r.Error == "stopped: the game started", "the player's game stops the model job (" + r.Error + ")");
                T.Eq(desk.Prompts.Count, 1, "no further run is queued");
                T.Ok(desk.CallCount("queue {\"delete\":[") == 1 && desk.CallCount("interrupt {\"prompt_id\":") == 1, "the run is taken out of ComfyUI's queue and interrupted, by its id");
                T.Eq(desk.CallCount("free"), 1, "and the card's memory let go for the game");
                m.Host.PlayerPlaying();
                T.Ok(m.Launcher.Starts.Count == 0 && Util.Wait(new ComfyClient(new HttpComfyHttp(), ComfyClient.At(m.DesktopPort)).StatsAsync(CancellationToken.None)) != null,
                    "Desktop's server is the member's: the game never stops it");
            }
            using (var m = new ModelRig())
            {
                m.Launcher.Outcome = p => "never";
                var t = Task.Run(() => m.R.Run("modeljob18", m.Plan(ModelRig.Run("a"))));
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while ((m.Launcher.Server == null || m.Launcher.Server.Prompts.Count == 0) && clock.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(10);
                m.R.Watch.Started = true;
                RunResult r = Util.Wait(t);
                T.Ok(!r.Ok && r.Error == "stopped: the game started", "the player's game stops a job on the app's own server (" + r.Error + ")");
                T.Ok(m.Launcher.Proc.Killed && !m.Host.OwnRunning, "and the app's own server goes at once, not after the idle wait");
                T.Has(m.Host.LastStop, "Death Muffin started", "because the game started");
            }
            using (var m = new ModelRig())
            {
                m.Host.IdleStop = TimeSpan.FromMinutes(5);
                RunResult r = m.R.Run("modeljob19", m.Plan(ModelRig.Run("a")));
                T.Ok(r.Ok && m.Host.OwnRunning, "after a job the app's own server waits for the next one (" + r.Error + ")");
                m.Host.PlayerPlaying();
                T.Ok(m.Launcher.Proc.Killed && !m.Host.OwnRunning, "the player's game stops an idle one at once");
            }
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                desk.Outcome = p => "never";
                var cancel = new CancellationTokenSource();
                var t = Task.Run(() => m.R.Run("modeljob16", m.Plan(ModelRig.Run("a")), cancelled: cancel.Token));
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (desk.Prompts.Count == 0 && clock.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(10);
                cancel.Cancel();
                RunResult r = Util.Wait(t);
                T.Ok(r.Cancelled, "a job the server cancels is dropped");
                T.Ok(desk.CallCount("interrupt") == 1, "and its run stopped in ComfyUI");
            }
            using (var m = new ModelRig())
            {
                FakeComfy desk = m.StartDesktop();
                desk.Outcome = p => FakeComfy.LabelOf(p) == "slow" ? "never" : "ok";
                m.R.Runner.ModelRunLimit = TimeSpan.FromMilliseconds(200);
                RunResult r = m.R.Run("modeljob17", m.Plan(ModelRig.Run("slow"), ModelRig.Run("quick")));
                T.Ok(r.Ok && string.Join(",", m.R.Api.DoneFiles ?? new List<string>()) == "quick.glb", "a run past its time limit is stopped and the next one runs (" + r.Error + ")");
                T.Has(r.Log, "run slow FAILED: The run took longer than", "the log says why");
                T.Eq(desk.CallCount("interrupt"), 1, "the slow run was interrupted in ComfyUI");
            }
        }

        static void Helpers()
        {
            T.Eq(JobRunner.GlbProblem(FakeComfy.Glb()), (string)null, "a whole binary glTF passes the app's check");
            byte[] cut = FakeComfy.Glb().Take(30).ToArray();
            T.Eq(JobRunner.GlbProblem(cut), "is cut off", "a model cut short does not");
            T.Eq(JobRunner.GlbProblem(Encoding.UTF8.GetBytes("<html>not found, really not a model</html>")), "is not a binary glTF model", "nor something else");
            T.Eq(JobRunner.ComfyStem("Ab12cd34ef56"), "Ab12cd34ef56", "a job id is its files' stem");
            T.Eq(JobRunner.ComfyStem("../x y"), "xy", "with only the letters a file name may have");
            T.Eq(ComfyRules.Gb(12282), "12.0 GB", "memory in the log's words");

            var tr = new Program.FakeTransport();
            var api = new TeamApi(tr, new Uri(TeamUrls.ApiBase)) { Token = "t" };
            Util.Wait(api.UploadAsync("ab12cd34ef56", "hound-pixal3d.glb", FakeComfy.Glb(), CancellationToken.None));
            T.Eq(tr.Sent.Count == 1 ? tr.Sent[0].ContentType : null, "model/gltf-binary", "a model is uploaded as a binary glTF");
            T.Ok(!Util.Wait(api.UploadAsync("ab12cd34ef56", "Hound.glb", FakeComfy.Glb(), CancellationToken.None)).Ok && tr.Sent.Count == 1, "a model's name follows the server's rule");
        }
    }
}
