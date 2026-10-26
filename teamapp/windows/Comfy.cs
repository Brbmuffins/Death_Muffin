using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

// The `model` job's side of ComfyUI (README.md "The model job"): the workflow, the calls to a ComfyUI server, finding ComfyUI Desktop and starting its server when nothing answers.
// No WinForms and no Windows calls (Platform.cs gives the process its Windows job object), so teamapp/tests compiles this file on Linux too.
namespace DeathMuffinTeam
{
    /// <summary>
    /// One run of a `model` job: ComfyUI's image-to-model workflow on one picture of the job (<see cref="Image"/>, a file of the job), with Pixal3D or TRELLIS.2 (<see cref="Model"/>), the face count the
    /// mesh is cut to before it is painted (<see cref="Faces"/>), the colour texture's size (<see cref="Texture"/>, the normal map's too) and the seed (<see cref="Seed"/>, added to the template's own seeds: 0 keeps them).
    /// The run's model is uploaded as `&lt;label&gt;.glb`.
    /// </summary>
    internal sealed class ModelRun
    {
        public string Label = "";
        public string Image = "";
        public string Model = ComfyRules.Pixal3d;
        public int Faces, Texture;
        public long Seed;

        /// <summary>"pixal3d, 5000 faces, texture 1024, seed 0" (the log's words for the run).</summary>
        public string Describe()
        {
            return Model + ", " + Faces.ToString(CultureInfo.InvariantCulture) + " faces, texture " + Texture.ToString(CultureInfo.InvariantCulture) + ", seed " + Seed.ToString(CultureInfo.InvariantCulture);
        }
    }

    /// <summary>The numbers of a `model` job.</summary>
    internal static class ComfyRules
    {
        public const string Pixal3d = "pixal3d";
        public const string Trellis2 = "trellis2";
        /// <summary>
        /// The graphics card a PC needs for model jobs, in MiB: 12 GB or more (Helix, 2026-10-26: "only run comfy ui on GPUs with 12GB+ vRAM"). A 12 GB card reports a little under 12,288 MiB (the
        /// 4070 SUPER: 12,282); an 11 GB card is under this.
        /// </summary>
        public const long MinVramMb = 11500;
        public static bool CardFits(long vramMb) { return vramMb >= MinVramMb; }
        public const int FacesMin = 500, FacesMax = 200000;
        public static readonly int[] TextureSizes = { 512, 1024, 2048, 4096 };
        public const int MaxRuns = 8;
        public const long SeedMax = 1000000;
        /// <summary>The server's limit for one model (team-jobs.cjs GLB_MAX_BYTES).</summary>
        public const int MaxModelBytes = 48 << 20;
        /// <summary>The older ComfyUI Desktop's server, when its window is open (Comfy Desktop's installs say their own port: ComfyInstall.Ports).</summary>
        public const int DesktopPort = 8000;
        /// <summary>The ports the app's own ComfyUI server may use: away from the Desktops' 8000 and 8188, so a Desktop opened later still gets its own.</summary>
        public const int OwnPortFirst = 8190, OwnPortLast = 8199;
        /// <summary>The app's own server must answer within this after it starts (the first start after a ComfyUI update is the slow one).</summary>
        public static readonly TimeSpan StartLimit = TimeSpan.FromMinutes(10);
        /// <summary>One run, from the moment it is queued in ComfyUI (a run queued behind the member's own work in Desktop waits for it).</summary>
        public static readonly TimeSpan RunLimit = TimeSpan.FromMinutes(30);
        /// <summary>The app's own server is stopped this long after its last job (a second job soon after does not wait for a start again).</summary>
        public static readonly TimeSpan IdleStop = TimeSpan.FromMinutes(10);
        /// <summary>The app's folder in ComfyUI's input and output folders: its pictures and models, named after the job, removed when the job ends.</summary>
        public const string Folder = "dmteam";

        public static string Gb(long mb) { return (mb / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " GB"; }
    }

    /// <summary>
    /// The workflow a `model` job runs: ComfyUI's "Pixal3D &amp; TRELLIS.2: Image to Model" template in the API format, made by teamapp/comfy/make-workflow.py and built into the app
    /// (teamapp/comfy/image-to-model.json). `slots` name the inputs a run fills in; a seed slot adds the run's seed to the template's own value (`seedBase`).
    /// </summary>
    internal sealed class ComfyWorkflow
    {
        public const string ResourceName = "image-to-model.json";
        static readonly string[] SlotNames = { "image", "trellis2", "faces", "texture", "seed", "prefix" };

        public string About = "";
        /// <summary>The node that saves the model (its output names the file).</summary>
        public string SaveNode = "";
        Dictionary<string, object> prompt;
        readonly Dictionary<string, List<KeyValuePair<string, string>>> slots = new Dictionary<string, List<KeyValuePair<string, string>>>();
        readonly Dictionary<string, long> seedBase = new Dictionary<string, long>();

        /// <summary>The workflow built into the app; null with the reason when it is missing or does not read (a broken build).</summary>
        public static ComfyWorkflow Embedded(out string error)
        {
            error = null;
            try
            {
                using (Stream s = typeof(ComfyWorkflow).Assembly.GetManifestResourceStream(ResourceName))
                {
                    if (s == null) { error = "The app has no model workflow built in."; return null; }
                    using (var r = new StreamReader(s, Encoding.UTF8)) return Parse(r.ReadToEnd(), out error);
                }
            }
            catch (IOException ex) { error = "The app's model workflow could not be read: " + ex.Message; return null; }
        }

        /// <summary>Reads and checks a workflow file: every slot names an input that is there and holds a plain value. Null with the reason otherwise.</summary>
        public static ComfyWorkflow Parse(string json, out string error)
        {
            error = null;
            var d = MiniJson.TryObject(json);
            var w = new ComfyWorkflow { About = MiniJson.Str(d, "about"), SaveNode = MiniJson.Str(d, "save"), prompt = MiniJson.Obj(d, "prompt") };
            if (d == null || w.prompt == null || w.prompt.Count == 0) { error = "The model workflow has no nodes."; return null; }
            if (!(w.prompt.ContainsKey(w.SaveNode))) { error = "The model workflow's save node is not one of its nodes."; return null; }
            var rawSlots = MiniJson.Obj(d, "slots");
            foreach (string name in SlotNames)
            {
                var list = MiniJson.Arr(rawSlots, name);
                if (list == null || list.Count == 0) { error = "The model workflow does not say where its " + name + " goes."; return null; }
                var into = new List<KeyValuePair<string, string>>();
                foreach (object o in list)
                {
                    var pair = o as List<object>;
                    string node = pair != null && pair.Count == 2 ? pair[0] as string : null, input = pair != null && pair.Count == 2 ? pair[1] as string : null;
                    var inputs = node == null ? null : MiniJson.Obj(MiniJson.Obj(w.prompt, node), "inputs");
                    object v = null;
                    if (inputs == null || input == null || !inputs.TryGetValue(input, out v) || v is List<object> || v is Dictionary<string, object>)
                    { error = "The model workflow's " + name + " slot names an input it does not have."; return null; }
                    into.Add(new KeyValuePair<string, string>(node, input));
                }
                w.slots[name] = into;
            }
            var bases = MiniJson.Obj(d, "seedBase");
            foreach (var s in w.slots["seed"])
            {
                long? b = MiniJson.Int(bases, s.Key);
                if (b == null) { error = "The model workflow gives no base seed for node " + s.Key + "."; return null; }
                w.seedBase[s.Key] = b.Value;
            }
            return w;
        }

        /// <summary>The nodes for one run, as ComfyUI's /prompt takes them (a copy: the workflow itself is never changed). <paramref name="image"/> is the picture's name in ComfyUI's input folder, <paramref name="prefix"/> where the model is saved.</summary>
        public Dictionary<string, object> Fill(ModelRun run, string image, string prefix)
        {
            var copy = (Dictionary<string, object>)MiniJson.Parse(MiniJson.Write(prompt));
            Set(copy, "image", image);
            Set(copy, "trellis2", run.Model == ComfyRules.Trellis2);
            Set(copy, "faces", (long)run.Faces);
            Set(copy, "texture", (long)run.Texture);
            Set(copy, "prefix", prefix);
            foreach (var s in slots["seed"]) Input(copy, s)[s.Value] = seedBase[s.Key] + run.Seed;
            return copy;
        }

        void Set(Dictionary<string, object> nodes, string slot, object value)
        {
            foreach (var s in slots[slot]) Input(nodes, s)[s.Value] = value;
        }

        static Dictionary<string, object> Input(Dictionary<string, object> nodes, KeyValuePair<string, string> s)
        {
            return MiniJson.Obj(MiniJson.Obj(nodes, s.Key), "inputs");
        }
    }

    // ---- Talking to a ComfyUI server ------------------------------------------------------------------------------------------------

    /// <summary>What came back from ComfyUI. NetworkError is set (and Status is 0) when nothing answered.</summary>
    internal sealed class ComfyReply
    {
        public int Status;
        public byte[] Body = new byte[0];
        public string NetworkError;

        public bool Ok { get { return Status >= 200 && Status < 300; } }
        public string Text { get { return Encoding.UTF8.GetString(Body ?? new byte[0]); } }
    }

    /// <summary>The one place the app talks to ComfyUI (on this PC only). Tests talk to a stand-in server through the real one.</summary>
    internal interface IComfyHttp
    {
        Task<ComfyReply> SendAsync(string method, Uri url, byte[] body, string contentType, TimeSpan timeout, CancellationToken ct);
    }

    internal sealed class HttpComfyHttp : IComfyHttp
    {
        // No proxy: ComfyUI is on this PC (a proxy set for the member's browsing must never see these calls).
        readonly HttpClient http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

        public async Task<ComfyReply> SendAsync(string method, Uri url, byte[] body, string contentType, TimeSpan timeout, CancellationToken ct)
        {
            try
            {
                using (var limit = new CancellationTokenSource(timeout))
                using (var both = CancellationTokenSource.CreateLinkedTokenSource(ct, limit.Token))
                using (var req = new HttpRequestMessage(new HttpMethod(method), url))
                {
                    if (body != null)
                    {
                        req.Content = new ByteArrayContent(body);
                        req.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
                    }
                    using (var resp = await http.SendAsync(req, both.Token).ConfigureAwait(false))
                        return new ComfyReply { Status = (int)resp.StatusCode, Body = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false) };
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex) { return new ComfyReply { NetworkError = ex.Message }; }
        }
    }

    /// <summary>A ComfyUI server's /system_stats: its version and its first graphics device (name, memory in MiB).</summary>
    internal sealed class ComfyStats
    {
        public string Version = "";
        public string Device = "";
        public long VramMb;
    }

    /// <summary>How a queued run stands: not finished yet, or finished with the saved model (its name in ComfyUI's output folder) or with ComfyUI's reason.</summary>
    internal sealed class ComfyOutcome
    {
        public bool Finished, Ok;
        public string Error = "";
        public string FileName = "", Subfolder = "", Type = "output";
    }

    /// <summary>
    /// ComfyUI's routes as a `model` job uses them: /system_stats, /upload/image, /prompt, /history/&lt;id&gt;, /view, /queue (delete), /interrupt and /free. A refusal or a failed run becomes a
    /// <see cref="JobFailure"/> (or an outcome) in plain words, with ComfyUI's own reason.
    /// </summary>
    internal sealed class ComfyClient
    {
        public readonly Uri Base;
        readonly IComfyHttp http;
        static readonly TimeSpan Short = TimeSpan.FromSeconds(5), Medium = TimeSpan.FromSeconds(30), Long = TimeSpan.FromMinutes(2);

        public ComfyClient(IComfyHttp http, Uri baseUrl) { this.http = http; Base = baseUrl; }

        public static Uri At(int port) { return new Uri("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "/"); }

        Uri U(string pathAndQuery) { return new Uri(Base, pathAndQuery); }

        /// <summary>The server's stats; null when nothing answers there like a ComfyUI server.</summary>
        public async Task<ComfyStats> StatsAsync(CancellationToken ct)
        {
            ComfyReply r = await http.SendAsync("GET", U("system_stats"), null, null, Short, ct).ConfigureAwait(false);
            var d = r.Ok ? MiniJson.TryObject(r.Text) : null;
            var system = MiniJson.Obj(d, "system");
            if (system == null) return null;
            var s = new ComfyStats { Version = MiniJson.Str(system, "comfyui_version") };
            var devices = MiniJson.Arr(d, "devices");
            var first = devices != null && devices.Count > 0 ? devices[0] as Dictionary<string, object> : null;
            if (first != null)
            {
                s.Device = MiniJson.Str(first, "name");
                long? bytes = MiniJson.Int(first, "vram_total");
                s.VramMb = bytes.HasValue ? bytes.Value / (1024 * 1024) : 0;
            }
            return s;
        }

        /// <summary>Puts a picture in ComfyUI's input folder (under <paramref name="subfolder"/>) and returns its name as LoadImage takes it ("dmteam/&lt;name&gt;").</summary>
        public async Task<string> UploadImageAsync(byte[] data, string name, string subfolder, CancellationToken ct)
        {
            string boundary = "----dmteam" + Guid.NewGuid().ToString("N");
            byte[] body = Multipart(boundary, new Dictionary<string, string> { { "subfolder", subfolder }, { "type", "input" }, { "overwrite", "true" } }, "image", name, data);
            ComfyReply r = await http.SendAsync("POST", U("upload/image"), body, "multipart/form-data; boundary=" + boundary, Long, ct).ConfigureAwait(false);
            var d = r.Ok ? MiniJson.TryObject(r.Text) : null;
            string stored = MiniJson.Str(d, "name");
            if (stored.Length == 0) throw new JobFailure("ComfyUI did not take the picture " + name + ": " + Why(r));
            string folder = MiniJson.Str(d, "subfolder");
            return folder.Length > 0 ? folder + "/" + stored : stored;
        }

        /// <summary>Queues a run (<paramref name="nodes"/>: ComfyWorkflow.Fill) and returns its prompt id. A workflow ComfyUI refuses (a missing model file, a node it lacks) is a <see cref="JobFailure"/> with its reasons.</summary>
        public async Task<string> QueueAsync(Dictionary<string, object> nodes, string clientId, CancellationToken ct)
        {
            byte[] body = Encoding.UTF8.GetBytes(MiniJson.Write(new Dictionary<string, object> { { "prompt", nodes }, { "client_id", clientId } }));
            ComfyReply r = await http.SendAsync("POST", U("prompt"), body, "application/json", Medium, ct).ConfigureAwait(false);
            var d = MiniJson.TryObject(r.Text);
            string id = MiniJson.Str(d, "prompt_id");
            if (r.Ok && id.Length > 0) return id;
            if (r.Status == 400 && d != null) throw new JobFailure("ComfyUI refused the model workflow: " + Refusal(d));
            throw new JobFailure("ComfyUI did not queue the run: " + Why(r));
        }

        /// <summary>How the run stands (<paramref name="saveNode"/>: the workflow's save node, whose output names the model file).</summary>
        public async Task<ComfyOutcome> ResultAsync(string promptId, string saveNode, CancellationToken ct)
        {
            ComfyReply r = await http.SendAsync("GET", U("history/" + Uri.EscapeDataString(promptId)), null, null, Medium, ct).ConfigureAwait(false);
            if (!r.Ok) throw new JobFailure("ComfyUI stopped answering while it made the model: " + Why(r));
            var entry = MiniJson.Obj(MiniJson.TryObject(r.Text), promptId);
            var o = new ComfyOutcome();
            if (entry == null) return o;   // queued or running: the history has it once it ends
            var status = MiniJson.Obj(entry, "status");
            string state = MiniJson.Str(status, "status_str");
            if (!MiniJson.Bool(status, "completed") && state != "error") return o;
            o.Finished = true;
            if (state == "error") { o.Error = RunError(MiniJson.Arr(status, "messages")); return o; }
            foreach (var kv in MiniJson.Obj(MiniJson.Obj(entry, "outputs"), saveNode) ?? new Dictionary<string, object>())
            {
                var items = kv.Value as List<object>;
                if (items == null) continue;
                foreach (object item in items)
                {
                    var f = item as Dictionary<string, object>;
                    string file = MiniJson.Str(f, "filename");
                    if (!file.EndsWith(".glb", StringComparison.OrdinalIgnoreCase)) continue;
                    o.Ok = true;
                    o.FileName = file;
                    o.Subfolder = MiniJson.Str(f, "subfolder");
                    string type = MiniJson.Str(f, "type");
                    if (type.Length > 0) o.Type = type;
                    return o;
                }
            }
            o.Error = "ComfyUI finished the run but saved no model.";
            return o;
        }

        /// <summary>A file of ComfyUI's output folder.</summary>
        public async Task<byte[]> ViewAsync(string fileName, string subfolder, string type, CancellationToken ct)
        {
            ComfyReply r = await http.SendAsync("GET", U("view?filename=" + Uri.EscapeDataString(fileName) + "&subfolder=" + Uri.EscapeDataString(subfolder ?? "") + "&type=" + Uri.EscapeDataString(type ?? "output")),
                null, null, Long, ct).ConfigureAwait(false);
            if (!r.Ok) throw new JobFailure("ComfyUI made the model but did not hand it over: " + Why(r));
            return r.Body;
        }

        /// <summary>Stops a run: out of the queue if it waits, interrupted if it runs (ComfyUI stops only that run when it knows the prompt id). Best effort, a few seconds at most, never throws.</summary>
        public async Task StopAsync(string promptId)
        {
            try
            {
                byte[] del = Encoding.UTF8.GetBytes(MiniJson.Write(new Dictionary<string, object> { { "delete", new List<object> { promptId } } }));
                await http.SendAsync("POST", U("queue"), del, "application/json", Short, CancellationToken.None).ConfigureAwait(false);
                byte[] stop = Encoding.UTF8.GetBytes(MiniJson.Write(new Dictionary<string, object> { { "prompt_id", promptId } }));
                await http.SendAsync("POST", U("interrupt"), stop, "application/json", Short, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception) { }
        }

        /// <summary>Lets go of the models and the graphics card's memory (the app's own server, after a job). Best effort, never throws.</summary>
        public async Task FreeAsync()
        {
            try
            {
                byte[] body = Encoding.UTF8.GetBytes(MiniJson.Write(new Dictionary<string, object> { { "unload_models", true }, { "free_memory", true } }));
                await http.SendAsync("POST", U("free"), body, "application/json", Short, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception) { }
        }

        /// <summary>A multipart/form-data body: the text fields, then one file.</summary>
        public static byte[] Multipart(string boundary, Dictionary<string, string> fields, string fileField, string fileName, byte[] data)
        {
            var ms = new MemoryStream();
            Action<string> put = s => { byte[] b = Encoding.UTF8.GetBytes(s); ms.Write(b, 0, b.Length); };
            foreach (var kv in fields) put("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + kv.Key + "\"\r\n\r\n" + kv.Value + "\r\n");
            put("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + fileField + "\"; filename=\"" + fileName + "\"\r\nContent-Type: " + ImageType(fileName) + "\r\n\r\n");
            ms.Write(data, 0, data.Length);
            put("\r\n--" + boundary + "--\r\n");
            return ms.ToArray();
        }

        static string ImageType(string name)
        {
            string ext = Path.GetExtension(name ?? "").ToLowerInvariant();
            return ext == ".png" ? "image/png" : ext == ".webp" ? "image/webp" : "image/jpeg";
        }

        /// <summary>The reasons in a /prompt refusal: its message, then each node's errors ("DecimateMesh: Value not in list: ..."), at most 600 characters.</summary>
        public static string Refusal(Dictionary<string, object> d)
        {
            var parts = new List<string>();
            var error = MiniJson.Obj(d, "error");
            string message = MiniJson.Str(error, "message");
            if (message.Length > 0) parts.Add(message.TrimEnd('.') + (MiniJson.Str(error, "details").Length > 0 ? " (" + MiniJson.Str(error, "details") + ")" : ""));
            foreach (var kv in MiniJson.Obj(d, "node_errors") ?? new Dictionary<string, object>())
            {
                var node = kv.Value as Dictionary<string, object>;
                foreach (object e in MiniJson.Arr(node, "errors") ?? new List<object>())
                {
                    var ed = e as Dictionary<string, object>;
                    string m = MiniJson.Str(ed, "message"), details = MiniJson.Str(ed, "details");
                    parts.Add(MiniJson.Str(node, "class_type") + ": " + m + (details.Length > 0 ? ": " + details : ""));
                }
            }
            return TextClip.Head(parts.Count > 0 ? string.Join("; ", parts) : "no reason given", 600);
        }

        /// <summary>ComfyUI's reason for a run that ended in an error: the node and its exception ("ComfyUI stopped at KSampler: CUDA out of memory"), or that it was interrupted.</summary>
        public static string RunError(List<object> messages)
        {
            foreach (object m in messages ?? new List<object>())
            {
                var pair = m as List<object>;
                if (pair == null || pair.Count < 2) continue;
                var info = pair[1] as Dictionary<string, object>;
                if ((pair[0] as string) == "execution_error")
                {
                    string type = MiniJson.Str(info, "exception_type"), msg = MiniJson.Str(info, "exception_message");
                    return TextClip.Head("ComfyUI stopped at " + MiniJson.Str(info, "node_type") + ": " + (msg.Length > 0 ? msg : type), 400);
                }
                if ((pair[0] as string) == "execution_interrupted") return "ComfyUI was interrupted while it made the model.";
            }
            return "ComfyUI could not make the model (it gave no reason).";
        }

        static string Why(ComfyReply r)
        {
            if (r.NetworkError != null) return "no answer (" + r.NetworkError + ")";
            string text = TextClip.Head(r.Text, 300);
            return "HTTP " + r.Status.ToString(CultureInfo.InvariantCulture) + (text.Length > 0 ? ", " + text : "");
        }
    }

    // ---- ComfyUI Desktop on this PC ---------------------------------------------------------------------------------------------------

    /// <summary>
    /// What the app needs to start ComfyUI's server without Desktop's window, from either Desktop. Comfy Desktop (the 2.0 app, Comfy-Org/Comfy-Desktop) keeps a list of ComfyUI installs
    /// (%APPDATA%\Comfy Desktop\installations.json), each a folder with its own ComfyUI, Python, models and custom nodes; the app takes the one launched last. The older ComfyUI Desktop
    /// (Comfy-Org/desktop) has one: its settings (%APPDATA%\ComfyUI\config.json, whose `basePath` is the ComfyUI folder the member chose, with the models, custom nodes and Desktop's Python in
    /// .venv), the ComfyUI it bundles (%LOCALAPPDATA%\Programs\&lt;app&gt;\resources\ComfyUI\main.py), its web page and its extra model folders. The layouts are the Desktops' own
    /// (Comfy Desktop: src/main/sources/*, src/main/models.ts; the older one: src/main-process/comfyServer.ts).
    /// </summary>
    internal sealed class ComfyInstall
    {
        /// <summary>Which ComfyUI this is, for the log ("Comfy Desktop's install \"ComfyUI\"").</summary>
        public string Name = "";
        public string Python = "", MainPy = "", BasePath = "", WorkingDir = "", Venv = "", FrontEnd = "", ExtraModels = "";
        /// <summary>Python's -s (no packages from the member's own Python folder), as Comfy Desktop starts ComfyUI.</summary>
        public bool NoUserSite;
        /// <summary>The ports this install's own server listens on when Desktop runs it (looked at before the app starts one; the older Desktop's 8000 is ComfyHost's own).</summary>
        public List<int> Ports = new List<int>();
        /// <summary>Comfy Desktop's records of the servers it started (&lt;userData&gt;\comfy-procs\*.json, each with its install's id and port): a server it started on another port is found too.</summary>
        public string ProcsDir = "", InstallId = "";
        /// <summary>The input and output folders of Desktop's own server ("" when not known), where a job run there leaves its files until it removes them.</summary>
        public string InputRoot = "", OutputRoot = "";

        /// <summary>Desktop's app folders under %LOCALAPPDATA%\Programs, the usual first (the folder's name has changed between Desktop versions); any other folder that bundles ComfyUI comes after them.</summary>
        static readonly string[] AppFolders = { "ComfyUI", "@comfyorgcomfyui-electron" };
        /// <summary>Comfy Desktop's folders in %APPDATA%, the current name first (it had others while it was new).</summary>
        static readonly string[] Desktop2Folders = { "Comfy Desktop", "ComfyUI Desktop 2.0", "ComfyUI Launcher", "comfyui-desktop-2", "comfyui-launcher" };
        /// <summary>The port Comfy Desktop's installs listen on unless their launch settings name one (ComfyUI's own default).</summary>
        public const int Desktop2Port = 8188;

        public static ComfyInstall Find(string appData, string localAppData, out string why) { return Find(appData, localAppData, null, out why); }

        /// <param name="desktopApps">The folders Windows says the older Desktop's program is in (its uninstall entry, a running ComfyUI.exe: WindowsPlatform.ComfyDesktopFolders), looked in first: its
        /// installer lets the member choose the folder, so it need not be under %LOCALAPPDATA%\Programs.</param>
        public static ComfyInstall Find(string appData, string localAppData, IEnumerable<string> desktopApps, out string why)
        {
            why = null;
            try
            {
                string why2, whyOld;
                ComfyInstall i = FindDesktop2(appData ?? "", out why2);
                if (i != null) return i;
                string config = Path.Combine(appData ?? "", "ComfyUI", "config.json");
                if (!File.Exists(config))
                {
                    why = why2 ?? "ComfyUI Desktop is not set up on this PC (no " + Path.Combine(appData ?? "", Desktop2Folders[0], "installations.json") + " or " + config + ")";
                    return null;
                }
                i = FindOlderDesktop(config, appData ?? "", localAppData ?? "", desktopApps, out whyOld);
                if (i == null) why = why2 == null ? whyOld : why2 + "; the older ComfyUI Desktop: " + whyOld;
                return i;
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException) { why = "ComfyUI Desktop's files could not be read: " + ex.Message; return null; }
        }

        /// <summary>Comfy Desktop's install launched last that can be started here (a ComfyUI folder on this PC with its Python and main.py). Null with no reason when Comfy Desktop is not set up.</summary>
        static ComfyInstall FindDesktop2(string appData, out string why)
        {
            why = null;
            foreach (string folder in Desktop2Folders)
            {
                string userData = Path.Combine(appData, folder);
                string list = Path.Combine(userData, "installations.json");
                if (!File.Exists(list)) continue;
                List<object> records;
                try { records = MiniJson.Parse(File.ReadAllText(list)) as List<object>; }
                catch (FormatException) { records = null; }
                if (records == null) { why = "Comfy Desktop's list of installs (" + list + ") does not read"; return null; }
                var settings = MiniJson.TryObject(ReadOrEmpty(Path.Combine(userData, "settings.json")));
                ComfyInstall best = null;
                double bestAt = double.MinValue;
                var skipped = new List<string>();
                foreach (object o in records)
                {
                    var r = o as Dictionary<string, object>;
                    string status = MiniJson.Str(r, "status");
                    if (r == null || (status.Length > 0 && status != "installed")) continue;
                    string whyNot;
                    ComfyInstall i = FromRecord(r, userData, settings, out whyNot);
                    if (i == null) { if (whyNot != null) skipped.Add(whyNot); continue; }
                    object at;
                    double when = r.TryGetValue("lastLaunchedAt", out at) && at is double ? (double)at : 0;
                    if (best == null || when > bestAt) { best = i; bestAt = when; }
                }
                if (best != null) return best;
                why = "Comfy Desktop has no ComfyUI install this app can start" + (skipped.Count > 0 ? ": " + string.Join("; ", skipped) : " (none of its installs is on this PC)");
                return null;
            }
            return null;
        }

        /// <summary>One install of Comfy Desktop's list, as Comfy Desktop would start it (its sources' getLaunchCommand); null for one that runs elsewhere (cloud, remote) or is the older Desktop's,
        /// and null with the reason for one whose files are missing.</summary>
        static ComfyInstall FromRecord(Dictionary<string, object> r, string userData, Dictionary<string, object> settings, out string why)
        {
            why = null;
            string id = MiniJson.Str(r, "id"), source = MiniJson.Str(r, "sourceId"), dir = MiniJson.Str(r, "installPath");
            string name = "Comfy Desktop's install \"" + (MiniJson.Str(r, "name").Length > 0 ? MiniJson.Str(r, "name") : id) + "\"";
            if (dir.Length == 0 || (source != "standalone" && source != "portable" && source != "git")) return null;
            if (!Directory.Exists(dir)) { why = name + " is not on this PC (no " + dir + ")"; return null; }
            var i = new ComfyInstall { Name = name, NoUserSite = true, InstallId = id, ProcsDir = Path.Combine(userData, "comfy-procs") };
            if (source == "standalone")
            {
                string adoptedBase = MiniJson.Bool(r, "adopted") ? MiniJson.Str(r, "adoptedBaseDir") : "";
                string adoptedPython = MiniJson.Bool(r, "adopted") ? MiniJson.Str(r, "adoptedPythonPath") : "";
                foreach (string p in new[] { adoptedPython, Path.Combine(dir, "ComfyUI", ".venv", "Scripts", "python.exe"), Path.Combine(dir, "envs", "default", "Scripts", "python.exe") })
                    if (p.Length > 0 && File.Exists(p)) { i.Python = p; break; }
                i.MainPy = Path.Combine(dir, "ComfyUI", "main.py");
                i.BasePath = adoptedBase.Length > 0 ? adoptedBase : Path.Combine(dir, "ComfyUI");
                i.WorkingDir = dir;
                if (i.Python.Length > 0) i.Venv = Path.GetDirectoryName(Path.GetDirectoryName(i.Python));
            }
            else if (source == "portable")
            {
                string root = Directory.Exists(Path.Combine(dir, "python_embeded")) ? dir : "";
                if (root.Length == 0) foreach (string sub in Directory.GetDirectories(dir)) if (Directory.Exists(Path.Combine(sub, "python_embeded"))) { root = sub; break; }
                if (root.Length == 0) { why = name + " has no python_embeded folder in " + dir; return null; }
                i.Python = Path.Combine(root, "python_embeded", "python.exe");
                i.MainPy = Path.Combine(root, "ComfyUI", "main.py");
                i.BasePath = Path.Combine(root, "ComfyUI");
                i.WorkingDir = root;
            }
            else
            {
                string venv = MiniJson.Str(r, "venvPath");
                i.Python = venv.Length > 0 ? Path.Combine(venv, "Scripts", "python.exe") : "";
                i.Venv = venv;
                i.MainPy = File.Exists(Path.Combine(dir, "main.py")) ? Path.Combine(dir, "main.py") : Path.Combine(dir, "ComfyUI", "main.py");
                i.BasePath = Path.GetDirectoryName(i.MainPy);
                i.WorkingDir = i.BasePath;
            }
            if (i.Python.Length == 0 || !File.Exists(i.Python)) { why = name + " has no Python in " + dir; return null; }
            if (!File.Exists(i.MainPy)) { why = name + " has no " + i.MainPy; return null; }
            // its model folders: the file Comfy Desktop writes for the install at each launch (models.ts instanceModelPathsYaml), or the shared one of older versions
            foreach (string y in new[] { Path.Combine(userData, "instance-model-paths", id + ".yaml"), Path.Combine(userData, "shared_model_paths.yaml") })
                if (id.Length > 0 && File.Exists(y)) { i.ExtraModels = y; break; }
            i.Ports.Add(PortIn(MiniJson.Str(r, "launchArgs")) ?? Desktop2Port);
            i.InputRoot = ServerFolder(r, settings, "Input", Path.Combine(i.BasePath, "input"), dir);
            i.OutputRoot = ServerFolder(r, settings, "Output", Path.Combine(i.BasePath, "output"), dir);
            return i;
        }

        /// <summary>
        /// Where Comfy Desktop's own server for the install keeps its input or output (launch.ts): the shared folder (settings.json, or by default ComfyUI-Shared next to the ComfyUI-Installs folder
        /// the install is in), or the install's own when it does not share. "" when not known.
        /// </summary>
        static string ServerFolder(Dictionary<string, object> r, Dictionary<string, object> settings, string which, string own, string installDir)
        {
            object shared;
            if (r.TryGetValue("useShared" + which, out shared) && shared is bool && !(bool)shared)
                return MiniJson.Str(r, which.ToLowerInvariant() + "Dir").Length > 0 ? MiniJson.Str(r, which.ToLowerInvariant() + "Dir") : own;
            string set = MiniJson.Str(settings, which.ToLowerInvariant() + "Dir");
            if (set.Length > 0) return set;
            string installs = Path.GetDirectoryName(installDir.TrimEnd('\\', '/'));
            return installs != null && string.Equals(Path.GetFileName(installs), "ComfyUI-Installs", StringComparison.OrdinalIgnoreCase)
                ? Path.Combine(Path.GetDirectoryName(installs) ?? "", "ComfyUI-Shared", which.ToLowerInvariant()) : "";
        }

        /// <summary>The port in launch settings ("--enable-manager --port 8189", "--port=8189"); null when they name none.</summary>
        public static int? PortIn(string launchArgs)
        {
            string[] a = (launchArgs ?? "").Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            int? port = null;
            for (int k = 0; k < a.Length; k++)
            {
                string v = a[k] == "--port" && k + 1 < a.Length ? a[k + 1] : a[k].StartsWith("--port=") ? a[k].Substring(7) : null;
                int n;
                if (v != null && int.TryParse(v, NumberStyles.None, CultureInfo.InvariantCulture, out n) && n > 0 && n < 65536) port = n;
            }
            return port;
        }

        /// <summary>The ports to look for this install's running server on: its own, then those of the servers Comfy Desktop says it started for it (read now: they change while the app runs).</summary>
        public List<int> ServerPorts()
        {
            var ports = new List<int>(Ports);
            try
            {
                if (ProcsDir.Length > 0 && Directory.Exists(ProcsDir))
                    foreach (string f in Directory.GetFiles(ProcsDir, "*.json"))
                    {
                        var rec = MiniJson.TryObject(ReadOrEmpty(f));
                        long? port = MiniJson.Int(rec, "port");
                        if (MiniJson.Str(rec, "installationId") == InstallId && port > 0 && port < 65536 && !ports.Contains((int)port.Value)) ports.Add((int)port.Value);
                    }
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException) { }
            return ports;
        }

        static string ReadOrEmpty(string path)
        {
            try { return File.Exists(path) ? File.ReadAllText(path) : ""; }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException) { return ""; }
        }

        static ComfyInstall FindOlderDesktop(string config, string appData, string localAppData, IEnumerable<string> desktopApps, out string why)
        {
            why = null;
            string basePath = MiniJson.Str(MiniJson.TryObject(File.ReadAllText(config)), "basePath");
            if (basePath.Length == 0 || !Directory.Exists(basePath)) { why = "ComfyUI Desktop's settings name no ComfyUI folder that exists"; return null; }
            string python = Path.Combine(basePath, ".venv", "Scripts", "python.exe");
            if (!File.Exists(python)) { why = "ComfyUI Desktop's Python is not in " + Path.Combine(basePath, ".venv"); return null; }
            string programs = Path.Combine(localAppData, "Programs");
            var apps = new List<string>();
            if (desktopApps != null) foreach (string a in desktopApps) if (!string.IsNullOrEmpty(a) && !apps.Contains(a)) apps.Add(a);
            int listed = apps.Count;
            foreach (string a in AppFolders) apps.Add(Path.Combine(programs, a));
            if (Directory.Exists(programs))
                foreach (string d in Directory.GetDirectories(programs)) if (!apps.Contains(d)) apps.Add(d);
            foreach (string app in apps)
            {
                string comfy = Path.Combine(app, "resources", "ComfyUI");
                string main = Path.Combine(comfy, "main.py");
                if (!File.Exists(main)) continue;
                string web = Path.Combine(comfy, "web_custom_versions", "desktop_app");
                string extra = Path.Combine(appData, "ComfyUI", "extra_models_config.yaml");
                return new ComfyInstall
                {
                    Name = "ComfyUI Desktop", Python = python, MainPy = main, BasePath = basePath, WorkingDir = basePath, Venv = Path.Combine(basePath, ".venv"),
                    FrontEnd = Directory.Exists(web) ? web : "", ExtraModels = File.Exists(extra) ? extra : "",
                    InputRoot = Path.Combine(basePath, "input"), OutputRoot = Path.Combine(basePath, "output"),   // its server's own folders (comfyServer.ts)
                };
            }
            why = "ComfyUI Desktop's program files (resources\\ComfyUI\\main.py) are not in " + programs + (listed > 0 ? " or " + string.Join(", ", apps.GetRange(0, listed)) : " and Windows names no other folder for it");
            return null;
        }

        /// <summary>The folder of the program an uninstall entry's DisplayIcon or UninstallString names: <c>C:\x\ComfyUI.exe,0</c> and <c>"C:\x\Uninstall ComfyUI.exe" /currentuser</c> give
        /// <c>C:\x</c>; "" when it names none.</summary>
        public static string ExeFolder(string command)
        {
            string s = (command ?? "").Trim();
            if (s.StartsWith("\"")) { int end = s.IndexOf('"', 1); s = end > 0 ? s.Substring(1, end - 1) : s.Substring(1); }
            else
            {
                int exe = s.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                if (exe >= 0) s = s.Substring(0, exe + 4);
            }
            if (!s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return "";
            try { return Path.GetDirectoryName(s) ?? ""; }
            catch (ArgumentException) { return ""; }
        }
    }

    /// <summary>Finds ComfyUI Desktop's files: null with the reason (plain words) when they are not there.</summary>
    internal delegate ComfyInstall ComfyInstallFinder(out string why);

    /// <summary>What the app starts: ComfyUI's main.py with Desktop's Python, its window hidden, at below-normal priority.</summary>
    internal sealed class ComfyLaunch
    {
        public string Python = "";
        public string WorkingDir = "";
        public List<string> Args = new List<string>();
        public Dictionary<string, string> Env = new Dictionary<string, string>();
    }

    /// <summary>Starts ComfyUI's server. The real one starts a process; tests start a stand-in server.</summary>
    internal interface IComfyLauncher
    {
        IGameProcess Start(ComfyLaunch launch);
    }

    /// <summary>
    /// The real launcher: no window, its output kept (the end of it goes in a job's log when the start fails), below-normal priority (the card does the work; the PC stays responsive). <paramref name="contain"/>
    /// (Windows: a job object that ends the server, and anything it started, when the app ends or crashes) returns what kills the whole tree; null for none.
    /// </summary>
    internal sealed class ProcessComfyLauncher : IComfyLauncher
    {
        readonly Func<Process, IDisposable> contain;

        public ProcessComfyLauncher(Func<Process, IDisposable> contain) { this.contain = contain; }

        public IGameProcess Start(ComfyLaunch l)
        {
            var psi = new ProcessStartInfo
            {
                FileName = l.Python,
                Arguments = CommandLineText.Join(l.Args),
                WorkingDirectory = l.WorkingDir,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var kv in l.Env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            var buffer = new OutputBuffer(64 * 1024);
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) => { if (e.Data != null) buffer.Add(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) buffer.Add(e.Data); };
            p.Start();
            IDisposable job = null;
            try { if (contain != null) job = contain(p); } catch (Exception) { }
            try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            return new Server(p, buffer, job);
        }

        sealed class Server : IGameProcess
        {
            readonly Process p;
            readonly OutputBuffer buffer;
            readonly IDisposable job;
            readonly int id;

            public Server(Process p, OutputBuffer buffer, IDisposable job) { this.p = p; this.buffer = buffer; this.job = job; id = p.Id; }

            public int Id { get { return id; } }

            public bool HasExited
            {
                get
                {
                    try { return p.HasExited; }
                    catch (InvalidOperationException) { return true; }
                }
            }

            public int ExitCode { get { try { return p.ExitCode; } catch (InvalidOperationException) { return -1; } } }

            public void Kill()
            {
                try { if (!p.HasExited) p.Kill(); }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
                try { if (job != null) job.Dispose(); } catch (Exception) { }   // whatever the server started goes with it
                try { p.WaitForExit(5000); } catch (Exception) { }
            }

            public void Tend() { }

            public string Output() { return buffer.Text(); }

            public void Dispose() { p.Dispose(); }
        }
    }

    /// <summary>
    /// Finds a ComfyUI server for a `model` job, starting one when none answers (Helix, 2026-10-26: "the team app should launch it if it is not already running"). A Desktop's own server is used when
    /// it runs (the install's ports, then the older Desktop's 8000: the member's settings, models and queue; the app's run waits behind the member's own work there). Otherwise the app starts ComfyUI from the
    /// install's files with its Python, its ComfyUI folder as the base (models, custom nodes) and the app's own user, input and output folders (under the app's folder, comfy\), on 127.0.0.1 only, port 8190 to 8199, hidden; it frees the
    /// card's memory after each job and stops 10 minutes after the last one, and when the app closes. The runner checks the card (12 GB or more) on whichever server it gets.
    /// </summary>
    internal sealed class ComfyHost : IDisposable
    {
        readonly IComfyHttp http;
        readonly IComfyLauncher launcher;
        readonly ComfyInstallFinder findInstall;
        readonly string ownRoot;
        readonly object gate = new object();
        IGameProcess own;
        int ownPort;
        int uses, generation;
        bool disposed;
        ComfyInstall cachedInstall;
        string cachedWhy;
        DateTime cachedAtUtc = DateTime.MinValue;

        public int DesktopPort = ComfyRules.DesktopPort, OwnPortFirst = ComfyRules.OwnPortFirst, OwnPortLast = ComfyRules.OwnPortLast;
        public TimeSpan StartLimit = ComfyRules.StartLimit, IdleStop = ComfyRules.IdleStop;
        public int PollMs = 1000;
        /// <summary>Whether a port is free to listen on (tests pick their own).</summary>
        public Func<int, bool> PortFree = DefaultPortFree;
        /// <summary>How long a found (or missing) install is believed before it is looked for again (the heartbeat asks every half a minute).</summary>
        public static readonly TimeSpan InstallCheckEvery = TimeSpan.FromMinutes(5);

        /// <param name="findInstall">Finds ComfyUI Desktop's files (ComfyInstall.Find); null with the reason when it is not installed.</param>
        /// <param name="ownRoot">The folder of the app's own server: its user, input and output folders.</param>
        public ComfyHost(IComfyHttp http, IComfyLauncher launcher, ComfyInstallFinder findInstall, string ownRoot)
        {
            this.http = http;
            this.launcher = launcher;
            this.findInstall = findInstall;
            this.ownRoot = ownRoot;
        }

        /// <summary>ComfyUI Desktop is installed here (what the heartbeat's `models` needs besides a 12 GB card). Looked up at most every <see cref="InstallCheckEvery"/>.</summary>
        public bool Installed { get { return Install(false) != null; } }

        /// <summary>Why ComfyUI Desktop was not found at the last look ("" when it was), for the heartbeat's `modelsWhy`.</summary>
        public string NotFoundWhy { get { string why; return Install(false, out why) == null ? why ?? "" : ""; } }

        ComfyInstall Install(bool fresh)
        {
            string why;
            return Install(fresh, out why);
        }

        ComfyInstall Install(bool fresh, out string why)
        {
            lock (gate)
            {
                if (fresh || DateTime.UtcNow - cachedAtUtc > InstallCheckEvery)
                {
                    try { cachedInstall = findInstall(out cachedWhy); }
                    catch (Exception ex) { cachedInstall = null; cachedWhy = ex.Message; }
                    cachedAtUtc = DateTime.UtcNow;
                }
                why = cachedWhy;
                return cachedInstall;
            }
        }

        /// <summary>A server a job may use until it disposes the lease: its client, whether it is the app's own, and its input and output folders ("" when not known: Desktop's server with Desktop's settings gone).</summary>
        internal sealed class Lease : IDisposable
        {
            readonly ComfyHost host;
            bool released;
            public readonly ComfyClient Client;
            public readonly bool Own;
            public readonly string InputRoot, OutputRoot;

            public Lease(ComfyHost host, ComfyClient client, bool own, string inputRoot, string outputRoot) { this.host = host; Client = client; Own = own; InputRoot = inputRoot; OutputRoot = outputRoot; }

            public void Dispose()
            {
                if (released) return;
                released = true;
                host.Release(this);
            }
        }

        /// <summary>A server that answers: Desktop's, the app's own that still runs, or the app's own started now. A <see cref="JobFailure"/> in plain words when there can be none.</summary>
        public async Task<Lease> AcquireAsync(Action<string> note, Action<string> progress, CancellationToken ct)
        {
            lock (gate)
            {
                if (disposed) throw new JobFailure("stopped: the team app was closed");
                uses++;
                generation++;   // an idle stop that was waiting is called off
            }
            try { return await FindOrStartAsync(note, progress, ct).ConfigureAwait(false); }
            catch (Exception)
            {
                Release(null);
                throw;
            }
        }

        async Task<Lease> FindOrStartAsync(Action<string> note, Action<string> progress, CancellationToken ct)
        {
            ComfyInstall found = Install(false);
            var ports = found == null ? new List<int>() : found.ServerPorts();
            if (!ports.Contains(DesktopPort)) ports.Add(DesktopPort);
            foreach (int p in ports)
            {
                var desktop = new ComfyClient(http, ComfyClient.At(p));
                ComfyStats stats = await desktop.StatsAsync(ct).ConfigureAwait(false);
                if (stats == null) continue;
                note("ComfyUI " + stats.Version + " is already running (port " + p + "): using it");
                return new Lease(this, desktop, false, found == null ? "" : found.InputRoot, found == null ? "" : found.OutputRoot);
            }
            IGameProcess running;
            int port;
            lock (gate) { running = own; port = ownPort; }
            if (running != null && !running.HasExited)
            {
                var mine = new ComfyClient(http, ComfyClient.At(port));
                if (await mine.StatsAsync(ct).ConfigureAwait(false) != null)
                {
                    note("the app's own ComfyUI is still running (port " + port + "): using it");
                    return OwnLease(mine);
                }
                StopOwn("it stopped answering");
            }
            return await StartOwnAsync(note, progress, ct).ConfigureAwait(false);
        }

        Lease OwnLease(ComfyClient client)
        {
            return new Lease(this, client, true, Path.Combine(ownRoot, "input"), Path.Combine(ownRoot, "output"));
        }

        async Task<Lease> StartOwnAsync(Action<string> note, Action<string> progress, CancellationToken ct)
        {
            string why;
            ComfyInstall install = Install(true, out why);
            if (install == null) throw new JobFailure("ComfyUI is not running and could not be started: " + (string.IsNullOrEmpty(why) ? "ComfyUI Desktop is not installed on this PC" : why) + ".");
            int port = -1;
            for (int p = OwnPortFirst; p <= OwnPortLast && port < 0; p++) if (PortFree(p)) port = p;
            if (port < 0) throw new JobFailure("ComfyUI could not be started: ports " + OwnPortFirst + " to " + OwnPortLast + " are all taken on this PC.");
            ComfyLaunch launch = LaunchFor(install, ownRoot, port);
            foreach (string sub in new[] { "user", "input", "output" }) Directory.CreateDirectory(Path.Combine(ownRoot, sub));
            note("starting ComfyUI (" + install.Name + ", " + install.BasePath + ", port " + port + "): " + launch.Python + " " + CommandLineText.Join(launch.Args));
            progress("Starting ComfyUI");
            IGameProcess proc;
            try { proc = launcher.Start(launch); }
            catch (Exception ex) { throw new JobFailure("ComfyUI could not be started: " + ex.Message); }
            lock (gate)
            {
                if (disposed) { proc.Kill(); proc.Dispose(); throw new JobFailure("stopped: the team app was closed"); }
                own = proc;
                ownPort = port;
            }
            var client = new ComfyClient(http, ComfyClient.At(port));
            var clock = Stopwatch.StartNew();
            while (true)
            {
                if (ct.IsCancellationRequested) { StopOwn("the job stopped"); throw new OperationCanceledException(ct); }
                if (proc.HasExited)
                {
                    string tail = TextClip.Tail(proc.Output(), 6000);
                    StopOwn(null);
                    if (tail.Length > 0) note("ComfyUI's output:\n" + tail);
                    throw new JobFailure("ComfyUI stopped while it was starting (exit code " + proc.ExitCode + "): the end of what it said is in the job's log.");
                }
                ComfyStats stats = await client.StatsAsync(ct).ConfigureAwait(false);
                if (stats != null)
                {
                    note("ComfyUI " + stats.Version + " answered after " + clock.Elapsed.TotalSeconds.ToString("0", CultureInfo.InvariantCulture) + " s");
                    return OwnLease(client);
                }
                if (clock.Elapsed > StartLimit)
                {
                    string tail = TextClip.Tail(proc.Output(), 6000);
                    StopOwn("it did not answer in time");
                    if (tail.Length > 0) note("ComfyUI's output:\n" + tail);
                    throw new JobFailure("ComfyUI did not answer within " + (int)StartLimit.TotalMinutes + " minutes of starting, so it was stopped.");
                }
                await Task.Delay(PollMs, ct).ConfigureAwait(false);
            }
        }

        /// <summary>
        /// The command that starts ComfyUI headless from Desktop's files, with the install's ComfyUI folder as its base (models, custom nodes) and the app's own folders, on 127.0.0.1 only: the core
        /// arguments both Desktops give (the older one's comfyServer.ts coreLaunchArgs; Comfy Desktop's -s and model folders file). The member's own launch settings are not used.
        /// </summary>
        public static ComfyLaunch LaunchFor(ComfyInstall install, string ownRoot, int port)
        {
            var args = new List<string>();
            if (install.NoUserSite) args.Add("-s");
            args.AddRange(new[] { install.MainPy, "--base-directory", install.BasePath,
                "--user-directory", Path.Combine(ownRoot, "user"), "--input-directory", Path.Combine(ownRoot, "input"), "--output-directory", Path.Combine(ownRoot, "output"),
                "--database-url", "sqlite:///" + Path.Combine(ownRoot, "user", "comfyui.db").Replace('\\', '/') });
            if (install.ExtraModels.Length > 0) { args.Add("--extra-model-paths-config"); args.Add(install.ExtraModels); }
            if (install.FrontEnd.Length > 0) { args.Add("--front-end-root"); args.Add(install.FrontEnd); }
            args.AddRange(new[] { "--listen", "127.0.0.1", "--port", port.ToString(CultureInfo.InvariantCulture) });
            var env = new Dictionary<string, string>
            {
                { "PATH", Path.GetDirectoryName(install.Python) + Path.PathSeparator + (Environment.GetEnvironmentVariable("PATH") ?? "") },
                { "PYTHONUNBUFFERED", "1" },        // its output arrives as it is written
                { "PYTHONIOENCODING", "utf-8" },    // a redirected Windows console is not UTF-8: a node printing a name in another script would stop ComfyUI
            };
            if (install.Venv.Length > 0) env["VIRTUAL_ENV"] = install.Venv;   // a portable ComfyUI's embedded Python has none
            return new ComfyLaunch { Python = install.Python, WorkingDir = install.WorkingDir.Length > 0 ? install.WorkingDir : install.BasePath, Args = args, Env = env };
        }

        void Release(Lease lease)
        {
            int gen;
            bool idle;
            lock (gate)
            {
                uses = Math.Max(0, uses - 1);
                gen = ++generation;
                idle = uses == 0 && own != null && !disposed;
            }
            if (!idle) return;
            // the app's own server waits IdleStop for the next job, then stops (a job in between calls it off)
            Task.Delay(IdleStop).ContinueWith(t =>
            {
                bool stop;
                lock (gate) stop = gen == generation && uses == 0;
                if (stop) StopOwn("no job for " + (int)IdleStop.TotalMinutes + " minutes");
            }, TaskScheduler.Default);
        }

        /// <summary>The app's own server, running now (tests and the log).</summary>
        public bool OwnRunning { get { lock (gate) return own != null && !own.HasExited; } }

        /// <summary>What the host did last (tests read it).</summary>
        public string LastStop = "";

        void StopOwn(string why)
        {
            IGameProcess p;
            lock (gate) { p = own; own = null; }
            End(p, why);
        }

        void End(IGameProcess p, string why)
        {
            if (p == null) return;
            LastStop = why ?? "";
            try { p.Kill(); } catch (Exception) { }
            try { p.Dispose(); } catch (Exception) { }
        }

        /// <summary>The player's Death Muffin runs: the app's own server stops now when no job uses it (an idle one still holds some of the card's memory), not after
        /// <see cref="IdleStop"/>. Desktop's is the member's and is left alone.</summary>
        public void PlayerPlaying()
        {
            IGameProcess p;
            lock (gate)
            {
                if (uses > 0) return;
                p = own;
                own = null;
            }
            End(p, "Death Muffin started");
        }

        /// <summary>The app closes: its own server goes with it (Desktop's is the member's and is left alone).</summary>
        public void Dispose()
        {
            lock (gate) disposed = true;
            StopOwn("the app closed");
        }

        static bool DefaultPortFree(int port)
        {
            try
            {
                var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, port);
                l.Start();
                l.Stop();
                return true;
            }
            catch (System.Net.Sockets.SocketException) { return false; }
        }
    }
}
