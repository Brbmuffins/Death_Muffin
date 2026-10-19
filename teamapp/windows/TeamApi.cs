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
            var c = new HttpClient { Timeout = TimeSpan.FromSeconds(120) };
            c.DefaultRequestHeaders.UserAgent.ParseAdd("DeathMuffinTeam/" + appVersion);
            return c;
        }

        public async Task<HttpReply> SendAsync(string method, Uri url, string teamToken, byte[] body, string contentType, CancellationToken ct)
        {
            try
            {
                using (var req = new HttpRequestMessage(new HttpMethod(method), url))
                {
                    if (!string.IsNullOrEmpty(teamToken)) req.Headers.Authorization = new AuthenticationHeaderValue(TeamApi.AuthScheme, teamToken);
                    if (body != null)
                    {
                        req.Content = new ByteArrayContent(body);
                        req.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
                    }
                    using (var resp = await http.SendAsync(req, ct).ConfigureAwait(false))
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

    internal sealed class Offer
    {
        public string Id = "";
        public string Kind = "";
        public string Title = "";
        public int WeightS;
        public string ExpiresAt = "";
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
        Task<ApiResult> ClaimAsync(string jobId, string pcId, CancellationToken ct);
        Task<ApiResult> DeclineAsync(string jobId, string pcId, string reason, CancellationToken ct);
        Task<ApiResult> UploadAsync(string jobId, string name, byte[] png, CancellationToken ct);
        Task<ApiResult> DoneAsync(string jobId, IList<string> files, string log, double downloadS, double runS, CancellationToken ct);
        Task<ApiResult> FailAsync(string jobId, string error, string log, CancellationToken ct);
    }

    /// <summary>
    /// The server's /api/team routes: the team sign-in and sign-out, the heartbeat, claim, decline, pictures, done and fail. Every call but the sign-in sends
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
            if (!PcIdRe.IsMatch(pcId ?? "")) return Task.FromResult(ApiResult.Local("This PC has no valid id."));
            var body = new Dictionary<string, object>
            {
                { "pcId", pcId }, { "name", TextClip.Head(name, 64) }, { "version", TextClip.Head(version, 32) }, { "gpu", TextClip.Head(gpu, 120) },
                { "mode", Modes.Wire(mode) }, { "state", state.ToJson() },
            };
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

        public Task<ApiResult> UploadAsync(string jobId, string name, byte[] png, CancellationToken ct)
        {
            if (!JobIdRe.IsMatch(jobId ?? "") || !FileNameRe.IsMatch(name ?? "")) return Task.FromResult(ApiResult.Local("The picture's name is not valid: " + name));
            return CallAsync("PUT", Url("team/jobs/" + jobId + "/files/" + name), true, png, "image/png", ct);
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

        public Task<ApiResult> FailAsync(string jobId, string error, string log, CancellationToken ct)
        {
            var body = new Dictionary<string, object> { { "error", TextClip.Head(error, 400) }, { "log", TextClip.Tail(log, 60000) } };
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
