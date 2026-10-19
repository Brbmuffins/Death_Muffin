using System;
using System.Collections.Generic;
using System.Globalization;

// The honest-numbers rules of the `bench` job: when a PC is quiet enough to start a benchmark, and when a run was disturbed. Pure functions over readings of the PC,
// with no Windows calls, so teamapp/tests compiles this file on Linux too (Platform.cs has the real reader).
namespace DeathMuffinTeam
{
    /// <summary>One reading of the PC.</summary>
    internal sealed class PcSample
    {
        /// <summary>When it was read, on the reader's own clock (only differences matter).</summary>
        public TimeSpan At;
        /// <summary>Percent of the whole CPU (every core) used by every process since the previous reading.</summary>
        public double CpuTotal;
        /// <summary>The part of CpuTotal the job's own game used (0 when it does not run).</summary>
        public double CpuGame;
        /// <summary>Seconds since the last key press or mouse move (GetLastInputInfo).</summary>
        public double IdleS;
        public bool OnBattery, Fullscreen;
        /// <summary>The player's own Death Muffin is running (not the job's game).</summary>
        public bool PlayerGame;

        /// <summary>What every other process used: the total minus the job's game.</summary>
        public double CpuOthers { get { return Math.Max(0, CpuTotal - CpuGame); } }
    }

    /// <summary>Reads the PC. The real one is in Platform.cs; tests script one.</summary>
    internal interface IPcProbe
    {
        /// <summary>Reads the PC now. <paramref name="gamePid"/> is the job's game process (0 when none runs), whose CPU is reported as CpuGame. The CPU numbers are
        /// averages since the previous Read, so the first Read of a stretch is not used for them.</summary>
        PcSample Read(int gamePid);
    }

    /// <summary>The numbers behind "quiet" and "disturbed" (ROADMAP Phase 1, the `bench` job's honest numbers).</summary>
    internal sealed class QuietRules
    {
        /// <summary>Before a run the PC must have been quiet this long: total CPU averaging under <see cref="QuietCpuPct"/>. The keyboard and mouse do not count (Helix,
        /// 2026-10-19: a team member may keep using the PC; what would skew the numbers is other programs' CPU, watched before and during a run).</summary>
        public TimeSpan QuietFor = TimeSpan.FromSeconds(60);
        public double QuietCpuPct = 15;
        /// <summary>Readings further apart than this mean the reader stalled (sleep, a hang): the stretch was not watched.</summary>
        public TimeSpan MaxGap = TimeSpan.FromSeconds(5);
        /// <summary>The window may start this long after its first reading (readings come about a second apart, so a minute is 59 s of them and one).</summary>
        public TimeSpan StartSlack = TimeSpan.FromSeconds(2);
        /// <summary>During a run: the other processes' CPU, averaged over any <see cref="OthersWindow"/> of the run (the whole run when it is shorter, once it is
        /// <see cref="OthersMinSpan"/> old), must not pass <see cref="OthersCpuPct"/>.</summary>
        public double OthersCpuPct = 20;
        public TimeSpan OthersWindow = TimeSpan.FromSeconds(30);
        public TimeSpan OthersMinSpan = TimeSpan.FromSeconds(10);
    }

    internal static class Quiet
    {
        /// <summary>
        /// "" when the PC is quiet enough to start a benchmark, else why not, in plain words. <paramref name="samples"/> are oldest first and end now. Quiet means: no full-screen
        /// app, Death Muffin not open, not on battery (now and through the last <see cref="QuietRules.QuietFor"/>), the total CPU (every process,
        /// nothing excluded) averaging under 15% over it, and the PC watched all that time (no gap between readings over <see cref="QuietRules.MaxGap"/>, the first reading no later than
        /// <see cref="QuietRules.StartSlack"/> after the window began).
        /// </summary>
        public static string WhyNotQuiet(IList<PcSample> samples, QuietRules r)
        {
            if (samples == null || samples.Count == 0) return "checking the PC";
            PcSample last = samples[samples.Count - 1];
            if (last.PlayerGame) return "Death Muffin is open";
            if (last.Fullscreen) return "a full-screen app is open";
            if (last.OnBattery) return "this PC is on battery";

            TimeSpan from = last.At - r.QuietFor;
            int first = -1;
            for (int i = 0; i < samples.Count; i++)
                if (samples[i].At >= from) { first = i; break; }
            bool watched = first >= 0 && samples[first].At - from <= r.StartSlack;
            double sum = 0;
            for (int i = first; i < samples.Count; i++)
            {
                PcSample s = samples[i];
                if (s.PlayerGame) return "Death Muffin was open a moment ago";
                if (s.Fullscreen) return "a full-screen app was open a moment ago";
                if (s.OnBattery) return "this PC was on battery a moment ago";
                if (i > first && s.At - samples[i - 1].At > r.MaxGap) { watched = false; first = i; sum = 0; }   // a stall: watching starts over from here
                sum += s.CpuTotal;
            }
            int n = samples.Count - first;
            double mean = sum / n;
            if (mean >= r.QuietCpuPct) return "other programs are using the CPU (about " + Pct(mean) + ")";
            if (!watched) return "watching the PC for a quiet minute (" + Seconds((last.At - samples[first].At).TotalSeconds) + " so far)";
            return "";
        }

        /// <summary>
        /// "" when a run that started at <paramref name="runStart"/> (the reader's clock) was left alone, else why it was disturbed: the player started Death Muffin, the PC
        /// went on battery, or the other processes used more than 20% of the CPU on average (over any 30 s of the run, or the
        /// whole run while it is shorter; the run must be 10 s old before this counts).
        /// </summary>
        public static string Disturbance(IList<PcSample> samples, TimeSpan runStart, QuietRules r)
        {
            var run = new List<PcSample>();
            foreach (PcSample s in samples) if (s.At >= runStart) run.Add(s);
            foreach (PcSample s in run)
            {
                if (s.PlayerGame) return "Death Muffin was started";
                if (s.OnBattery) return "the PC went on battery";
            }
            for (int e = 0; e < run.Count; e++)
            {
                double sum = 0;
                int lo = e;
                while (lo >= 0 && run[e].At - run[lo].At < r.OthersWindow) { sum += run[lo].CpuOthers; lo--; }
                int n = e - lo;
                if (n == 0 || run[e].At - run[lo + 1].At < r.OthersMinSpan) continue;
                double mean = sum / n;
                if (mean > r.OthersCpuPct) return "other programs were using the CPU (about " + Pct(mean) + ")";
            }
            return "";
        }

        static string Seconds(double s) { return Math.Max(0, (int)Math.Round(s)).ToString(CultureInfo.InvariantCulture) + " s"; }

        static string Pct(double p) { return ((int)Math.Round(p)).ToString(CultureInfo.InvariantCulture) + "%"; }
    }
}
