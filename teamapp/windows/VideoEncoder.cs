using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace DeathMuffinTeam
{
    /// <summary>How making one clip's video went: the mp4's size and the quality step that fit, or why there is none.</summary>
    internal sealed class EncodeResult
    {
        public bool Ok;
        public string Error = "";
        public long Bytes;
        public int Crf;
        public double Seconds;
    }

    /// <summary>Turns a clip the game recorded (motion JPEG) into the mp4 the server keeps and Discord shows. The real one runs ffmpeg on this PC; tests use stand-ins.</summary>
    internal interface IVideoEncoder
    {
        Task<EncodeResult> EncodeAsync(string ffmpeg, string mjpeg, int fps, string mp4, CancellationToken ct);
    }

    /// <summary>
    /// The team PC makes each clip's mp4 itself (Helix 2026-10-19: videos at 1080p, 60 frames a second): a 1080p 60 fps clip of motion JPEG is about 150 MB, its mp4 a few MB, so only the mp4 is uploaded.
    /// H.264 (libx264), yuv420p, at most 10 seconds, no sound, the moov atom first (it plays while it loads). Quality steps from CRF 20 with at most 6 Mbit/s down to CRF 28 with 2.5 Mbit/s until the file is under
    /// <see cref="JobPlan.MaxMp4Bytes"/> (Discord's limit for the bot). ffmpeg runs below normal priority (the PC may be in use) and is stopped after <see cref="Limit"/>.
    /// </summary>
    internal sealed class FfmpegEncoder : IVideoEncoder
    {
        public TimeSpan Limit = TimeSpan.FromMinutes(3);

        /// <summary>The quality steps: (CRF, the highest bit rate in kbit/s).</summary>
        public static readonly int[][] Steps = { new[] { 20, 6000 }, new[] { 24, 4000 }, new[] { 28, 2500 } };

        /// <summary>ffmpeg's arguments for one try.</summary>
        public static List<string> Args(string mjpeg, int fps, string mp4, int crf, int maxKbps)
        {
            string rate = fps.ToString(CultureInfo.InvariantCulture);
            return new List<string>
            {
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "mjpeg", "-framerate", rate, "-i", mjpeg, "-t", "10",
                "-c:v", "libx264", "-preset", "medium", "-crf", crf.ToString(CultureInfo.InvariantCulture),
                "-maxrate", maxKbps.ToString(CultureInfo.InvariantCulture) + "k", "-bufsize", (maxKbps * 2).ToString(CultureInfo.InvariantCulture) + "k",
                "-r", rate, "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", "-f", "mp4", mp4,
            };
        }

        public async Task<EncodeResult> EncodeAsync(string ffmpeg, string mjpeg, int fps, string mp4, CancellationToken ct)
        {
            var clock = Stopwatch.StartNew();
            string part = mp4 + ".part";
            string why = "";
            try
            {
                foreach (int[] step in Steps)
                {
                    ct.ThrowIfCancellationRequested();
                    TryDelete(part);
                    why = await RunAsync(ffmpeg, Args(mjpeg, fps, part, step[0], step[1]), ct).ConfigureAwait(false);
                    if (why.Length > 0) break;
                    long bytes = File.Exists(part) ? new FileInfo(part).Length : 0;
                    if (bytes == 0) { why = "ffmpeg made an empty file"; break; }
                    if (bytes > JobPlan.MaxMp4Bytes) { why = "the video is " + (bytes / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB even at its lowest quality step"; continue; }
                    TryDelete(mp4);
                    File.Move(part, mp4);
                    return new EncodeResult { Ok = true, Bytes = bytes, Crf = step[0], Seconds = clock.Elapsed.TotalSeconds };
                }
            }
            finally { TryDelete(part); }
            return new EncodeResult { Error = why.Length > 0 ? why : "ffmpeg did not make the video", Seconds = clock.Elapsed.TotalSeconds };
        }

        /// <summary>Runs ffmpeg with an argument list (never a shell): "" when it ended with code 0, else why not, with the end of what it said.</summary>
        async Task<string> RunAsync(string ffmpeg, List<string> args, CancellationToken ct)
        {
            var psi = new ProcessStartInfo
            {
                FileName = ffmpeg,
                Arguments = CommandLineText.Join(args),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
            };
            Process p;
            try { p = Process.Start(psi); }
            catch (Exception ex) { return "ffmpeg could not be started (" + ex.Message + ")"; }
            using (p)
            {
                try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
                Task<string> err = p.StandardError.ReadToEndAsync();
                Task<string> outText = p.StandardOutput.ReadToEndAsync();
                var clock = Stopwatch.StartNew();
                while (!p.HasExited)
                {
                    if (ct.IsCancellationRequested || clock.Elapsed > Limit)
                    {
                        try { p.Kill(); } catch (Exception) { }
                        try { p.WaitForExit(5000); } catch (Exception) { }
                        ct.ThrowIfCancellationRequested();
                        return "ffmpeg took longer than " + (int)Limit.TotalMinutes + " minutes";
                    }
                    await Task.Delay(100).ConfigureAwait(false);
                }
                p.WaitForExit();
                string said = (await err.ConfigureAwait(false)).Trim();
                await outText.ConfigureAwait(false);
                if (p.ExitCode == 0) return "";
                return "ffmpeg ended with code " + p.ExitCode + (said.Length > 0 ? ": " + TextClip.Tail(said.Replace('\r', ' ').Replace('\n', ' '), 300) : "");
            }
        }

        static void TryDelete(string file)
        {
            try { if (File.Exists(file)) File.Delete(file); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
