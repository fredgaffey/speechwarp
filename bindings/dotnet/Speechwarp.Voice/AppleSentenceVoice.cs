using System;
using System.Threading.Tasks;
using AVFoundation;
using Foundation;

namespace Speechwarp.Voice;

/// <summary>
/// One of Apple's voices (Eloquence or any other installed voice) as an <see cref="ISentenceVoice"/>, for
/// <see cref="VoicedText"/> and anything else that works with any engine.
/// </summary>
/// <example>
/// <code>
/// using var voice = new AppleSentenceVoice("com.apple.eloquence.en-US.Reed");
/// float[] samples = voice.Speak("Hello there.");   // mono, voice.SampleRate
/// </code>
/// </example>
/// <remarks>
/// The system delivers speech on the main thread, so <see cref="Speak"/> asks for it there and waits on the
/// calling thread. Call it from a background thread, as <see cref="VoicedText"/> does. Called on the main thread
/// it does not deadlock: it runs the main run loop until the speech is ready, which also lets other work queued
/// for the main thread (UI events among it) run meanwhile, so avoid that where you can.
/// </remarks>
public sealed class AppleSentenceVoice : ISentenceVoice
{
    /// <summary>The prefix of every <see cref="Id"/>: "apple:".</summary>
    public const string IdPrefix = "apple:";

    private readonly SpeechRenderer _renderer;
    private readonly float _rate;

    /// <summary>The voice speaking.</summary>
    public SpeechVoice Voice { get; }

    /// <summary>"apple:" and the system's identifier, such as "apple:com.apple.eloquence.en-US.Reed".</summary>
    public string Id { get; }

    /// <summary>
    /// The rate the voice says it speaks at (22,050 for Eloquence and most others). Speech that comes back at
    /// another rate is converted to it.
    /// </summary>
    public int SampleRate { get; }

    /// <summary>The system rate the voice speaks at (see <see cref="SpeechRate"/>).</summary>
    public float Rate => _rate;

    /// <summary>How long <see cref="Speak"/> waits for the system before giving up. Default one minute.</summary>
    public TimeSpan Timeout { get; set; } = TimeSpan.FromMinutes(1);

    /// <summary>A voice that speaks at the system <paramref name="rate"/> (default <see cref="SpeechRate.Normal"/>).</summary>
    /// <exception cref="ArgumentException">The voice is not installed.</exception>
    public AppleSentenceVoice(SpeechVoice voice, float? rate = null)
    {
        ArgumentNullException.ThrowIfNull(voice);
        _renderer = new SpeechRenderer(voice);
        Voice = voice;
        Id = IdPrefix + voice.Identifier;
        _rate = rate ?? SpeechRate.Normal;
        SampleRate = SampleRateOf(voice.Identifier);
    }

    /// <summary>
    /// The installed voice with this system identifier, given bare ("com.apple.eloquence.en-US.Reed") or as an
    /// <see cref="Id"/> ("apple:com.apple.eloquence.en-US.Reed").
    /// </summary>
    /// <exception cref="ArgumentException">The voice is not installed.</exception>
    public AppleSentenceVoice(string identifier, float? rate = null)
        : this(SpeechVoice.Find(Bare(identifier))
            ?? throw new ArgumentException($"The voice {identifier} is not installed.", nameof(identifier)), rate)
    {
    }

    /// <summary>The system identifier in <paramref name="id"/>, with or without the "apple:" prefix.</summary>
    public static string Bare(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        return id.StartsWith(IdPrefix, StringComparison.Ordinal) ? id[IdPrefix.Length..] : id;
    }

    /// <summary>Speaks <paramref name="sentence"/> and waits for it; mono samples at <see cref="SampleRate"/>.</summary>
    /// <exception cref="TimeoutException">The system did not finish within <see cref="Timeout"/>.</exception>
    /// <exception cref="InvalidOperationException">The system produced no audio for the text.</exception>
    public float[] Speak(string sentence)
    {
        if (string.IsNullOrWhiteSpace(sentence))
            return [];
        Task<RenderedSpeech> rendering;
        if (NSThread.IsMain)
        {
            // Waiting here would block the thread the speech arrives on: run its loop instead.
            rendering = _renderer.RenderAsync(sentence, _rate);
            var deadline = DateTime.UtcNow + Timeout;
            while (!rendering.IsCompleted && DateTime.UtcNow < deadline)
                NSRunLoop.Main.RunUntil(NSRunLoopMode.Default, NSDate.FromTimeIntervalSinceNow(0.01));
        }
        else
        {
            rendering = _renderer.RenderAsync(sentence, _rate);
            rendering.Wait(Timeout);
        }
        if (!rendering.IsCompleted)
            throw new TimeoutException($"The voice {Voice.Identifier} did not finish speaking within {Timeout.TotalSeconds:0} s.");
        var speech = rendering.GetAwaiter().GetResult();
        return speech.SampleRate == SampleRate ? speech.Samples : AudioResampling.Linear(speech.Samples, speech.SampleRate, SampleRate);
    }

    /// <summary>The rate an installed voice says it speaks at; 22,050 where it does not say.</summary>
    internal static int SampleRateOf(string identifier)
    {
        var settings = AVSpeechSynthesisVoice.FromIdentifier(identifier)?.AudioFileSettings;
        return settings?[AVAudioSettings.AVSampleRateKey] is NSNumber number && number.Int32Value > 0 ? number.Int32Value : 22050;
    }

    /// <summary>Releases the system synthesiser.</summary>
    public void Dispose() => _renderer.Dispose();
}

/// <summary>Converting mono audio from one sample rate to another.</summary>
internal static class AudioResampling
{
    /// <summary>Linear interpolation: good enough for speech going from 22,050 to 24,000 and the like.</summary>
    public static float[] Linear(ReadOnlySpan<float> samples, int source, int target)
    {
        if (source == target || samples.Length == 0)
            return samples.ToArray();
        var result = new float[(int)((long)samples.Length * target / source)];
        for (var i = 0; i < result.Length; i++)
        {
            var x = (double)i * source / target;
            var j = (int)x;
            var f = (float)(x - j);
            result[i] = j + 1 < samples.Length ? samples[j] * (1 - f) + samples[j + 1] * f : samples[^1];
        }
        return result;
    }
}
