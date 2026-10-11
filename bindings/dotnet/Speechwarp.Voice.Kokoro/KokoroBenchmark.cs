using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Speechwarp.Voice.Kokoro;

/// <summary>What <see cref="KokoroBenchmark.Run"/> measured.</summary>
/// <param name="Engines">How many engines spoke at once.</param>
/// <param name="Paragraphs">Paragraphs spoken.</param>
/// <param name="AudioSeconds">Seconds of audio produced.</param>
/// <param name="ElapsedSeconds">Seconds it took, after loading.</param>
/// <param name="LoadSeconds">Seconds the first engine took to load the model.</param>
public sealed record KokoroBenchmarkResult(int Engines, int Paragraphs, double AudioSeconds, double ElapsedSeconds,
    double LoadSeconds)
{
    /// <summary>Seconds of work for each second of audio: below 1 is faster than listening.</summary>
    public double RealTimeFactor => AudioSeconds > 0 ? ElapsedSeconds / AudioSeconds : double.PositiveInfinity;

    /// <summary>Seconds of audio for each second of work, the inverse: above 1 is faster than listening.</summary>
    public double TimesRealTime => ElapsedSeconds > 0 ? AudioSeconds / ElapsedSeconds : 0;
}

/// <summary>
/// How fast Kokoro speaks on this device: speaks paragraphs of a text for a while and measures the audio produced.
/// Nothing is played. Run it on the device that matters (a phone is several times slower than a Mac).
/// </summary>
public static class KokoroBenchmark
{
    /// <summary>
    /// Speaks the paragraphs of <paramref name="text"/> (separated by blank lines), in order, until they run out or
    /// <paramref name="duration"/> has passed, with <paramref name="parallel"/> engines speaking different paragraphs
    /// at once (to see whether running several helps).
    /// </summary>
    /// <param name="directory">The model directory.</param>
    /// <param name="phonemizer">Turns words into IPA; it must be safe to call from several threads if parallel is above 1.</param>
    /// <param name="text">What to speak.</param>
    /// <param name="voice">The voice, <see cref="KokoroModels.DefaultVoice"/> unless given.</param>
    /// <param name="options">How each engine loads the model.</param>
    /// <param name="duration">How long to keep going: 60 s unless given. A paragraph under way is finished.</param>
    /// <param name="parallel">Engines speaking at once, 1 or more.</param>
    public static KokoroBenchmarkResult Run(string directory, IPhonemizer phonemizer, string text,
        string voice = KokoroModels.DefaultVoice, KokoroOptions? options = null, TimeSpan? duration = null, int parallel = 1)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentOutOfRangeException.ThrowIfLessThan(parallel, 1);
        var limit = duration ?? TimeSpan.FromSeconds(60);
        var paragraphs = text.Split(["\r\n\r\n", "\n\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        var watch = Stopwatch.StartNew();
        var engines = new List<KokoroEngine> { new(directory, phonemizer, options) };
        var load = watch.Elapsed.TotalSeconds;
        try
        {
            for (var i = 1; i < parallel; i++)
                engines.Add(new KokoroEngine(directory, phonemizer, options));
            var next = -1;
            var spoken = 0;
            var frames = 0L;
            watch.Restart();
            var workers = engines.Select(engine => Task.Run(() =>
            {
                while (watch.Elapsed < limit)
                {
                    var i = Interlocked.Increment(ref next);
                    if (i >= paragraphs.Length)
                        break;
                    Interlocked.Add(ref frames, engine.Speak(paragraphs[i], voice).Length);
                    Interlocked.Increment(ref spoken);
                }
            })).ToArray();
            Task.WaitAll(workers);
            return new KokoroBenchmarkResult(parallel, spoken, frames / (double)KokoroEngine.SampleRate,
                watch.Elapsed.TotalSeconds, load);
        }
        finally
        {
            foreach (var engine in engines)
                engine.Dispose();
        }
    }
}
