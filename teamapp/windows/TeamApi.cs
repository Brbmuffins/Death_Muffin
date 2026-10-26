using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam
{
    /// <summary>What came back over the wire. NetworkError is set (and Status is 0) when there was no answer at all.</summary>
    internal sealed class HttpReply
    {
        public int Status;
        public string Body = "";
        public string NetworkError;
    }

    /// <summary>The one place the app touches the network for the server's routes. Tests swap it for a stand-in; HttpClientTransport is the real one.</summary>
    internal interface ITransport
    {
        /// <param name="teamToken">The member's team token, sent as `Authorization: Team &lt;token&gt;`; empty for the sign-in itself.</param>
        Task<HttpReply> SendAsync(string method, Uri url, string teamToken, byte[] body, string contentType, CancellationToken ct);
    }

    internal sealed class HttpClientTransport : ITransport
    {
        readonly HttpClient http;

        public HttpClientTransport(HttpClient http) { this.http = http; }

        public static HttpClient CreateClient(string appVersion)
        {
            System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
            // no timeout of the client's own: each request has the limit TimeoutFor gives it (a heartbeat 40 seconds, a clip upload or a clip job's `done` longer)
            var c = new HttpClient { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
            c.DefaultRequestHeaders.UserAgent.ParseAdd("DeathMuffinTeam/" + appVersion);
            return c;
        }

        /// <summary>
        /// How long a request may take. A heartbeat 40 seconds (the server holds it up to 25). Most others are small: 2 minutes. A request that sends more than a megabyte (a clip is up to 48 MB, on a home
        /// connection's upload speed) or finishes a job (a clip job's `done` waits while the server turns each clip into a video) gets 6.
        /// </summary>
        public static TimeSpan TimeoutFor(Uri url, byte[] body)
        {
            if (url != null && url.AbsolutePath.EndsWith("/heartbeat", StringComparison.Ordinal)) return TeamLogic.HeartbeatTimeout;
            bool longRequest = (body != null && body.Length > (1 << 20)) || (url != null && url.AbsolutePath.EndsWith("/done", StringComparison.Ordinal));
            return longRequest ? TimeSpan.FromMinutes(6) : TimeSpan.FromMinutes(2);
        }

        public async Task<HttpReply> SendAsync(string method, Uri url, string teamToken, byte[] body, string contentType, CancellationToken ct)
        {
            try
            {
                using (var timeout = new CancellationTokenSource(TimeoutFor(url, body)))
                using (var both = CancellationTokenSource.CreateLinkedTokenSource(ct, timeout.Token))
                using (var req = new HttpRequestMessage(new HttpMethod(method), url))
                {
                    if (!string.IsNullOrEmpty(teamToken)) req.Headers.Authorization = new AuthenticationHeaderValue(TeamApi.AuthScheme, teamToken);
                    if (body != null)
                    {
                        req.Content = new ByteArrayContent(body);
                        req.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
                    }
                    using (var resp = await http.SendAsync(req, both.Token).ConfigureAwait(false))
                    {
                        string text = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                        return new HttpReply { Status = (int)resp.StatusCode, Body = text };
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex) { return new HttpReply { NetworkError = ex.Message }; }
        }
    }

    /// <summary>One answer of the server, read: success, the HTTP status, the server's own `code` and `error` (player-readable, shown as they are) and its `data`.</summary>
    internal sealed class ApiResult
    {
        public bool Ok;
        public int Status;
        public string Code = "";
        public string Error = "";
        public bool Network;
        public Dictionary<string, object> Data;

        /// <summary>The account is not on the team (403 not_team): the app stops.</summary>
        public bool NotTeam { get { return Status == 403 && Code == "not_team"; } }
        /// <summary>The team token is not accepted any more (401, code signed_out): the member must sign in again.</summary>
        public bool SignedOut { get { return Status == 401; } }
        /// <summary>Another PC got the job, or it expired or was cancelled (409 taken).</summary>
        public bool Taken { get { return Status == 409 && Code == "taken"; } }

        public static ApiResult Local(string error) { return new ApiResult { Error = error }; }
    }

    /// <summary>How one step of a `release` job went, as `done` and `fail` report it: the step's name, whether it worked, why not, and how long it took (for `install`, the milliseconds to the game's first screen).
    /// <see cref="Skipped"/>: left out on purpose (a benchmark on a PC with benchmarks off), with Ok true and the reason in Error.</summary>
    internal sealed class StepReport
    {
        public string Step = "";
        public bool Ok;
        public bool Skipped;
        public string Error = "";
        public long Ms;

        public Dictionary<string, object> ToJson()
        {
            var d = new Dictionary<string, object> { { "step", Step }, { "ok", Ok } };
            if (Skipped) d["skipped"] = true;
            if (Error.Length > 0) d["error"] = TextClip.Head(Error, 400);
            d["ms"] = Ms;
            return d;
        }
    }

    /// <summary>A job this PC may take: the heartbeat's offer, or one of its `queue` (the job list in the box). <see cref="RequestedBy"/> and <see cref="Thread"/>: who started the Discord thread it came
    /// from and the thread's name ("" when it came another way); <see cref="Steps"/>: a release job's steps (empty when the server did not say).</summary>
    internal sealed class Offer
    {
        public string Id = "";
        public string Kind = "";
        public string Title = "";
        public int WeightS;
        public string ExpiresAt = "";
        public string RequestedBy = "";
        public string Thread = "";
        public List<string> Steps = new List<string>();

        /// <summary>A benchmark and nothing else: a `bench` job, or a release job whose only step is the benchmark (left alone while benchmarks are off on this PC).</summary>
        public bool BenchmarkOnly { get { return Kind == JobPlan.BenchKind || (Kind == JobPlan.ReleaseKind && Steps.Count > 0 && Steps.TrueForAll(x => x == "bench")); } }

        /// <summary>A job with a benchmark in it (it takes the whole screen for a while).</summary>
        public bool HasBenchmark { get { return Kind == JobPlan.BenchKind || (Kind == JobPlan.ReleaseKind && Steps.Contains("bench")); } }
    }

    /// <summary>A job of the heartbeat's `queue`: one this PC may take, oldest first (the box lists them, the AFK notice too).</summary>
    internal sealed class QueuedJob
    {
        public string Id = "";
        public string Kind = "";
        public string Title = "";
        public int WeightS;
        public string ExpiresAt = "";
        public string RequestedBy = "";
        public string Thread = "";
        public List<string> Steps = new List<string>();

        public Offer ToOffer()
        {
            return new Offer { Id = Id, Kind = Kind, Title = Title, WeightS = WeightS, ExpiresAt = ExpiresAt, RequestedBy = RequestedBy, Thread = Thread, Steps = new List<string>(Steps) };
        }
    }

    internal sealed class ClaimedJob
    {
        public string Id = "";
        public string Kind = "";
        public string Title = "";
        /// <summary>The payload as parsed JSON (JobPlan.TryParse checks it).</summary>
        public object Payload;
    }

    /// <summary>The server's team routes, as the runner and the controller use them (tests use a stand-in).</summary>
    internal interface ITeamApi
    {
        string Token { get; set; }
        /// <summary>The team sign-in (it never touches the game session). Data: token, expiresAt, accountId, username.</summary>
        Task<ApiResult> LoginAsync(string username, string password, string pcId, string pcName, CancellationToken ct);
        /// <summary>Ends this token on the server (Sign out).</summary>
        Task<ApiResult> LogoutAsync(CancellationToken ct);
        Task<ApiResult> HeartbeatAsync(string pcId, string name, string version, string gpu, OfferMode mode, PcState state, CancellationToken ct);
        /// <summary>The heartbeat as a long poll: <paramref name="waitS"/> (0 to 25) asks the server to hold it while it has nothing to say (0: answer at once).</summary>
        Task<ApiResult> HeartbeatAsync(string pcId, string name, string version, string gpu, OfferMode mode, PcState state, int waitS, CancellationToken ct);
        Task<ApiResult> ClaimAsync(string jobId, string pcId, CancellationToken ct);
        Task<ApiResult> DeclineAsync(string jobId, string pcId, string reason, CancellationToken ct);
        /// <summary>Uploads one result file as the raw body: a picture (`.png`, sent as image/png), a clip's video (`.mp4`, video/mp4) or a release step's result (`.json`, application/json).</summary>
        Task<ApiResult> UploadAsync(string jobId, string name, byte[] data, CancellationToken ct);
        Task<ApiResult> DoneAsync(string jobId, IList<string> files, string log, double downloadS, double runS, CancellationToken ct);
        /// <summary>Finishes a `bench` job: <paramref name="runs"/> are the benchmark payloads as the game queued them (one per setup, at most 6, each at most 64 KB of JSON).</summary>
        /// <summary>Finishes a `release` job: how each step went, the pictures and step results it uploaded, and the bench step's runs (null or empty: none).</summary>
        Task<ApiResult> DoneReleaseAsync(string jobId, IList<StepReport> steps, IList<string> files, IList<Dictionary<string, object>> runs, string log, double downloadS, double runS, CancellationToken ct);
        Task<ApiResult> DoneBenchAsync(string jobId, IList<Dictionary<string, object>> runs, string log, double downloadS, double runS, CancellationToken ct);
        Task<ApiResult> FailAsync(string jobId, string error, string log, CancellationToken ct);
        /// <summary>The same for a `release` job that stops halfway: the steps it finished are reported with it.</summary>
        Task<ApiResult> FailAsync(string jobId, string error, string log, IList<StepReport> steps, CancellationToken ct);
    }

    /// <summary>
    /// The server's /api/team routes: the team sign-in and sign-out, the heartbeat, claim, decline, pictures, done (with the pictures, or with a benchmark's runs) and fail. Every call but the sign-in sends
    /// `Authorization: Team <token>`. Every reply is the server's `{success, data}` or `{success:false, code, error}`; `error` strings are
    /// player-readable and are passed on as they are. A reply that is not JSON (a proxy's error page) becomes a plain sentence.
    /// </summary>
    internal sealed class TeamApi : ITeamApi
    {
        /// <summary>The Authorization scheme of every team route.</summary>
        public const string AuthScheme = "Team";
        /// <summary>What the member sees when the server no longer accepts the token.</summary>
        public const string SignedOutText = "Signed out: sign in to the team app again.";

        static readonly Regex JobIdRe = new Regex("^[A-Za-z0-9]{1,24}$", RegexOptions.CultureInvariant);
        static readonly Regex FileNameRe = new Regex("^[a-z0-9_-]{1,60}\\.png$", RegexOptions.CultureInvariant);
        static readonly Regex Mp4NameRe = new Regex("^[a-z0-9][a-z0-9_-]{0,59}\\.mp4$", RegexOptions.CultureInvariant);
        static readonly Regex JsonNameRe = new Regex("^[a-z0-9][a-z0-9_-]{0,59}\\.json$", RegexOptions.CultureInvariant);
        static readonly Regex GlbNameRe = new Regex("^[a-z0-9][a-z0-9_-]{0,59}\\.glb$", RegexOptions.CultureInvariant);
        public const string PngType = "image/png";
        /// <summary>The content type of a `model` job's model (a binary glTF, team app 0.5.0).</summary>
        public const string GlbType = "model/gltf-binary";
        /// <summary>The content type of a step's result file (a `release` job).</summary>
        public const string JsonType = "application/json";
        /// <summary>The content type of a clip's video (made on this PC since team app 0.4.5).</summary>
        public const string Mp4Type = "video/mp4";
        static readonly Regex PcIdRe = new Regex("^[A-Za-z0-9_-]{8,64}$", RegexOptions.CultureInvariant);

        readonly ITransport transport;
        readonly Uri apiBase;

        public string Token { get; set; }

        /// <param name="apiBase">The game's API root, ending in "/" (TeamUrls.ApiBase).</param>
        public TeamApi(ITransport transport, Uri apiBase)
        {
            this.transport = transport;
            this.apiBase = apiBase;
            Token = "";
        }

        Uri Url(string path) { return new Uri(apiBase, path); }
        static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s); }

        public async Task<ApiResult> LoginAsync(string username, string password, string pcId, string pcName, CancellationToken ct)
        {
            if (!PcIdRe.IsMatch(pcId ?? "")) return ApiResult.Local("This PC has no valid id.");
            var body = MiniJson.Write(new Dictionary<string, object> { { "username", username }, { "password", password }, { "pcId", pcId }, { "pcName", TextClip.Head(pcName, 64) } });
            ApiResult r = await CallAsync("POST", Url("team/login"), false, Utf8(body), "application/json", ct).ConfigureAwait(false);
            if (r.Ok && MiniJson.Str(r.Data, "token").Length == 0)
            {
                r.Ok = false;
                r.Error = "The server's answer had no sign-in token.";
            }
            return r;
        }

        public Task<ApiResult> LogoutAsync(CancellationToken ct)
        {
            return CallAsync("POST", Url("team/logout"), true, Utf8("{}"), "application/json", ct);
        }

        public Task<ApiResult> HeartbeatAsync(string pcId, string name, string version, string gpu, OfferMode mode, PcState state, CancellationToken ct)
        {
            return HeartbeatAsync(pcId, name, version, gpu, mode, state, 0, ct);
        }

        public Task<ApiResult> HeartbeatAsync(string pcId, string name, string version, string gpu, OfferMode mode, PcState state, int waitS, CancellationToken ct)
        {
            if (!PcIdRe.IsMatch(pcId ?? "")) return Task.FromResult(ApiResult.Local("This PC has no valid id."));
            var body = new Dictionary<string, object>
            {
                { "pcId", pcId }, { "name", TextClip.Head(name, 64) }, { "version", TextClip.Head(version, 32) }, { "gpu", TextClip.Head(gpu, 120) },
                { "mode", Modes.Wire(mode) }, { "state", state.ToJson() },
            };
            if (waitS > 0) body["wait"] = Math.Min(waitS, TeamLogic.HeartbeatWaitS);
            return CallAsync("POST", Url("team/heartbeat"), true, Utf8(MiniJson.Write(body)), "application/json", ct);
        }

        public Task<ApiResult> ClaimAsync(string jobId, string pcId, CancellationToken ct)
        {
            return JobCall("claim", jobId, new Dictionary<string, object> { { "pcId", pcId } }, ct);
        }

        public Task<ApiResult> DeclineAsync(string jobId, string pcId, string reason, CancellationToken ct)
        {
            return JobCall("decline", jobId, new Dictionary<string, object> { { "pcId", pcId }, { "reason", reason } }, ct);
        }

        public Task<ApiResult> UploadAsync(string jobId, string name, byte[] data, CancellationToken ct)
        {
            // a picture (`.png`, image/png), a clip's video (`.mp4`, video/mp4), a step's result (`.json`, application/json) or a model (`.glb`, model/gltf-binary): the name says which
            string n = name ?? "";
            bool mp4 = Mp4NameRe.IsMatch(n), result = JsonNameRe.IsMatch(n), model = GlbNameRe.IsMatch(n);
            if (!JobIdRe.IsMatch(jobId ?? "") || !(mp4 || result || model || FileNameRe.IsMatch(n)))
                return Task.FromResult(ApiResult.Local("The " + (n.EndsWith(".mp4", StringComparison.Ordinal) ? "clip" : n.EndsWith(".json", StringComparison.Ordinal) ? "result" : n.EndsWith(".glb", StringComparison.Ordinal) ? "model" : "picture") + "'s name is not valid: " + name));
            return CallAsync("PUT", Url("team/jobs/" + jobId + "/files/" + name), true, data, mp4 ? Mp4Type : result ? JsonType : model ? GlbType : PngType, ct);
        }

        public Task<ApiResult> DoneAsync(string jobId, IList<string> files, string log, double downloadS, double runS, CancellationToken ct)
        {
            var body = new Dictionary<string, object>
            {
                { "files", files },
                { "log", TextClip.Tail(log, 60000) },
                { "timings", new Dictionary<string, object> { { "downloadS", Math.Round(downloadS, 1) }, { "runS", Math.Round(runS, 1) } } },
            };
            return JobCall("done", jobId, body, ct);
        }

        public Task<ApiResult> DoneBenchAsync(string jobId, IList<Dictionary<string, object>> runs, string log, double downloadS, double runS, CancellationToken ct)
        {
            var body = new Dictionary<string, object>
            {
                { "files", new List<string>() },
                { "runs", runs },
                { "log", TextClip.Tail(log, 60000) },
                { "timings", new Dictionary<string, object> { { "downloadS", Math.Round(downloadS, 1) }, { "runS", Math.Round(runS, 1) } } },
            };
            return JobCall("done", jobId, body, ct);
        }

        public Task<ApiResult> DoneReleaseAsync(string jobId, IList<StepReport> steps, IList<string> files, IList<Dictionary<string, object>> runs, string log, double downloadS, double runS, CancellationToken ct)
        {
            var body = new Dictionary<string, object>
            {
                { "steps", StepsJson(steps) },
                { "files", files },
                { "log", TextClip.Tail(log, 60000) },
                { "timings", new Dictionary<string, object> { { "downloadS", Math.Round(downloadS, 1) }, { "runS", Math.Round(runS, 1) } } },
            };
            if (runs != null && runs.Count > 0) body["runs"] = runs;
            return JobCall("done", jobId, body, ct);
        }

        static List<object> StepsJson(IList<StepReport> steps)
        {
            var list = new List<object>();
            if (steps != null) foreach (StepReport s in steps) list.Add(s.ToJson());
            return list;
        }

        public Task<ApiResult> FailAsync(string jobId, string error, string log, CancellationToken ct)
        {
            return FailAsync(jobId, error, log, null, ct);
        }

        public Task<ApiResult> FailAsync(string jobId, string error, string log, IList<StepReport> steps, CancellationToken ct)
        {
            var body = new Dictionary<string, object> { { "error", TextClip.Head(error, 400) }, { "log", TextClip.Tail(log, 60000) } };
            if (steps != null && steps.Count > 0) body["steps"] = StepsJson(steps);
            return JobCall("fail", jobId, body, ct);
        }

        Task<ApiResult> JobCall(string verb, string jobId, Dictionary<string, object> body, CancellationToken ct)
        {
            if (!JobIdRe.IsMatch(jobId ?? "")) return Task.FromResult(ApiResult.Local("The job's id is not valid."));
            return CallAsync("POST", Url("team/jobs/" + jobId + "/" + verb), true, Utf8(MiniJson.Write(body)), "application/json", ct);
        }

        async Task<ApiResult> CallAsync(string method, Uri url, bool auth, byte[] body, string contentType, CancellationToken ct)
        {
            HttpReply r = await transport.SendAsync(method, url, auth ? Token : "", body, contentType, ct).ConfigureAwait(false);
            return Read(r);
        }

        /// <summary>Turns a reply into an ApiResult: `{success, data}` is a success, `{success:false, code, error}` (or any non-2xx) a failure with the server's own words.</summary>
        public static ApiResult Read(HttpReply r)
        {
            var res = new ApiResult { Status = r.Status };
            if (r.NetworkError != null)
            {
                res.Network = true;
                res.Error = "Could not reach the server. Check the internet connection.";
                return res;
            }
            var d = MiniJson.TryObject(r.Body);
            bool ok2xx = r.Status >= 200 && r.Status < 300;
            if (d == null)
            {
                res.Error = ok2xx ? "The server's answer could not be read." : "The server answered with an error (HTTP " + r.Status + ").";
                return res;
            }
            res.Code = MiniJson.Str(d, "code");
            res.Error = MiniJson.Str(d, "error");
            object success;
            bool failed = d.TryGetValue("success", out success) && success is bool && !(bool)success;
            res.Ok = ok2xx && !failed;
            res.Data = MiniJson.Obj(d, "data") ?? new Dictionary<string, object>();
            if (!res.Ok && res.Error.Length == 0)
                res.Error = r.Status == 401 ? SignedOutText : "The server refused this (HTTP " + r.Status + ").";
            return res;
        }

        // ---- Reading what the routes return ------------------------------------------------------------------------------------

        /// <summary>The heartbeat's offer: the oldest queued job, or null.</summary>
        public static Offer ParseOffer(ApiResult heartbeat)
        {
            var o = MiniJson.Obj(heartbeat == null ? null : heartbeat.Data, "offer");
            if (o == null) return null;
            string id = MiniJson.Str(o, "id");
            if (!JobIdRe.IsMatch(id)) return null;
            return new Offer
            {
                Id = id,
                Kind = MiniJson.Str(o, "kind"),
                Title = MiniJson.Str(o, "title"),
                WeightS = (int)Math.Max(0, Math.Min(86400, MiniJson.Int(o, "weightS") ?? 0)),
                ExpiresAt = MiniJson.Str(o, "expiresAt"),
            };
        }

        /// <summary>Did the heartbeat bring a `queue` at all (a server from before 0.4.1's notice sends none: the offer is then the only job known)?</summary>
        public static bool HasQueue(ApiResult heartbeat) { return MiniJson.Arr(heartbeat == null ? null : heartbeat.Data, "queue") != null; }

        /// <summary>The heartbeat's `queue`, in order, at most <see cref="MaxQueue"/> (a server from before it, or a bad entry, gives nothing for it).</summary>
        public static List<QueuedJob> ParseQueue(ApiResult heartbeat)
        {
            var jobs = new List<QueuedJob>();
            var list = MiniJson.Arr(heartbeat == null ? null : heartbeat.Data, "queue");
            if (list == null) return jobs;
            foreach (object o in list)
            {
                var d = o as Dictionary<string, object>;
                if (d == null || jobs.Count >= MaxQueue) continue;
                string id = MiniJson.Str(d, "id");
                if (!JobIdRe.IsMatch(id)) continue;
                var steps = new List<string>();
                var rawSteps = MiniJson.Arr(d, "steps");
                if (rawSteps != null) foreach (object x in rawSteps) { string n = x as string; if (n != null && n.Length > 0 && n.Length <= 20) steps.Add(n); }
                jobs.Add(new QueuedJob
                {
                    Id = id, Kind = MiniJson.Str(d, "kind"), Title = MiniJson.Str(d, "title"), WeightS = (int)Math.Max(0, Math.Min(86400, MiniJson.Int(d, "weightS") ?? 0)),
                    ExpiresAt = MiniJson.Str(d, "expiresAt"), RequestedBy = TextClip.Head(MiniJson.Str(d, "requestedBy"), 64), Thread = TextClip.Head(MiniJson.Str(d, "thread"), 120), Steps = steps,
                });
            }
            return jobs;
        }

        /// <summary>The most queued jobs the app keeps from a heartbeat (the server sends at most 20).</summary>
        public const int MaxQueue = 20;

        /// <summary>The heartbeat's `cancel`: the ids of jobs this PC is running that the server has cancelled (nothing to report, or a bad entry, gives nothing for it).</summary>
        public static List<string> ParseCancel(ApiResult heartbeat)
        {
            var ids = new List<string>();
            var list = MiniJson.Arr(heartbeat == null ? null : heartbeat.Data, "cancel");
            if (list == null) return ids;
            foreach (object o in list)
            {
                string id = o as string;
                if (id != null && JobIdRe.IsMatch(id) && !ids.Contains(id)) ids.Add(id);
            }
            return ids;
        }

        public static ClaimedJob ParseClaim(ApiResult claim)
        {
            if (claim == null || !claim.Ok || claim.Data == null) return null;
            string id = MiniJson.Str(claim.Data, "id");
            if (!JobIdRe.IsMatch(id)) return null;
            object payload;
            claim.Data.TryGetValue("payload", out payload);
            return new ClaimedJob { Id = id, Kind = MiniJson.Str(claim.Data, "kind"), Title = MiniJson.Str(claim.Data, "title"), Payload = payload };
        }
    }

    /// <summary>Clips text to the server's limits (it refuses a longer error or log).</summary>
    internal static class TextClip
    {
        public static string Head(string s, int maxChars)
        {
            s = (s ?? "").Replace('\r', ' ').Replace('\n', ' ').Trim();
            return s.Length > maxChars ? s.Substring(0, maxChars - 3) + "..." : s;
        }

        /// <summary>The last part of a log that fits in <paramref name="maxBytes"/> as UTF-8: the end of a log is what says why it failed.</summary>
        public static string Tail(string s, int maxBytes)
        {
            s = s ?? "";
            if (s.Length > maxBytes) s = s.Substring(s.Length - maxBytes);
            while (Encoding.UTF8.GetByteCount(s) > maxBytes && s.Length > 0) s = s.Substring(Math.Max(1, s.Length / 20));
            return s;
        }
    }
}
