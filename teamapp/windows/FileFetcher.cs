using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam
{
    /// <summary>
    /// Downloads one file of a job and proves it: into `&lt;name&gt;.part` (kept and resumed with an HTTP Range request after a dropped connection or a restart),
    /// then size and SHA-256 are checked and the file is renamed into place. A file that fails its check is deleted, never resumed on top of. A file
    /// that is already in place and passes the check is not downloaded again.
    /// </summary>
    internal sealed class FileFetcher
    {
        readonly HttpClient http;
        public int MaxAttempts = 4;
        public TimeSpan RetryDelay = TimeSpan.FromSeconds(1.5);
        /// <summary>A transfer with no bytes for this long counts as failed (and is retried).</summary>
        public TimeSpan StallTimeout = TimeSpan.FromSeconds(30);

        public FileFetcher(HttpClient http) { this.http = http; }

        /// <summary>HttpClient for the big downloads: no total timeout (the stall timeout watches each transfer).</summary>
        public static HttpClient CreateClient(string appVersion)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var c = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            c.DefaultRequestHeaders.UserAgent.ParseAdd("DeathMuffinTeam/" + appVersion);
            return c;
        }

        /// <summary>Makes sure <paramref name="dest"/> holds the file. Returns true when it was downloaded, false when it was already there and correct. Throws IOException when every attempt failed.</summary>
        public async Task<bool> EnsureAsync(PlanFile f, string dest, Action<long> report, CancellationToken ct)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(dest));
            if (Hashing.Verify(dest, f.Bytes, f.Sha256)) { report(f.Bytes); return false; }
            string part = dest + ".part";
            for (int attempt = 1; ; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    long have = File.Exists(part) ? new FileInfo(part).Length : 0;
                    if (have > f.Bytes) { File.Delete(part); have = 0; }
                    if (have < f.Bytes) await Transfer(f, part, have, report, ct).ConfigureAwait(false);
                    if (new FileInfo(part).Length != f.Bytes) throw new IOException("incomplete download");
                    if (!Hashing.Verify(part, f.Bytes, f.Sha256))
                    {
                        File.Delete(part);   // never resume on top of bad bytes
                        throw new IOException("the file did not match its checksum");
                    }
                    if (File.Exists(dest)) File.Delete(dest);
                    File.Move(part, dest);
                    report(f.Bytes);
                    return true;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    if (attempt >= MaxAttempts) throw new IOException("Could not download " + f.Name + ": " + ex.Message, ex);
                    await Task.Delay(TimeSpan.FromMilliseconds(RetryDelay.TotalMilliseconds * attempt), ct).ConfigureAwait(false);
                }
            }
        }

        async Task Transfer(PlanFile f, string part, long have, Action<long> report, CancellationToken ct)
        {
            using (var req = new HttpRequestMessage(HttpMethod.Get, f.Url))
            {
                if (have > 0) req.Headers.Range = new RangeHeaderValue(have, null);
                using (var stall = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    stall.CancelAfter(StallTimeout);
                    using (var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false))
                    {
                        // Disposing the response is what actually interrupts a hung read on .NET Framework.
                        using (stall.Token.Register(() => { try { resp.Dispose(); } catch (Exception) { } }))
                        {
                            if (resp.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable) { File.Delete(part); throw new IOException("the server rejected the resume range"); }
                            if (!resp.IsSuccessStatusCode) throw new IOException("the server answered HTTP " + (int)resp.StatusCode);
                            bool append = have > 0 && resp.StatusCode == HttpStatusCode.PartialContent;
                            if (!append) have = 0;   // the server ignored the Range header: start the file over
                            long got = have;
                            report(got);
                            using (var src = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false))
                            using (var dst = new FileStream(part, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
                            {
                                var buf = new byte[1 << 16];
                                int n;
                                while ((n = await src.ReadAsync(buf, 0, buf.Length, stall.Token).ConfigureAwait(false)) > 0)
                                {
                                    got += n;
                                    if (got > f.Bytes) throw new IOException("the file is larger than the job says");
                                    await dst.WriteAsync(buf, 0, n, ct).ConfigureAwait(false);
                                    report(Math.Min(got, f.Bytes));
                                    stall.CancelAfter(StallTimeout);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
