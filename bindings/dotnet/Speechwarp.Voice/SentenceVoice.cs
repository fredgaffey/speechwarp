using System;

namespace Speechwarp.Voice;

// The engine-independent face of text-to-speech. An engine speaks one sentence at a time; the live reader
// (VoicedText) and the cache (VoiceCache) work with any engine. Engines: Apple's voices (this package), Kokoro
// (Speechwarp.Voice.Kokoro, Speechwarp.Voice.Kokoro.Gpu) and eSpeak NG (Speechwarp.Voice.Espeak, GPL-3).

/// <summary>An engine that speaks one sentence at a time, at its own sample rate.</summary>
/// <remarks>
/// Called from one background thread at a time; <see cref="Speak"/> may take as long as it needs (it is never
/// called on the audio thread or the main thread).
/// </remarks>
public interface ISentenceVoice : IDisposable
{
    /// <summary>
    /// Identifies the voice and engine, stable across runs, such as "apple:com.apple.eloquence.en-US.Reed",
    /// "kokoro:af_heart" or "espeak:en-gb". Cached audio is kept per voice id.
    /// </summary>
    string Id { get; }

    /// <summary>Frames a second of what <see cref="Speak"/> returns. Mono.</summary>
    int SampleRate { get; }

    /// <summary>Speaks <paramref name="sentence"/>; returns mono samples, -1 to 1 (empty for nothing to say).</summary>
    float[] Speak(string sentence);

    /// <summary>
    /// The engine is slower than listening (neural voices on a phone): what it speaks is worth keeping on disk
    /// (<see cref="VoiceCache"/>) and speaking far ahead.
    /// </summary>
    bool KeepsSpoken => false;
}

/// <summary>Turns text into phonemes (IPA) for a neural voice such as Kokoro.</summary>
public interface IPhonemizer
{
    /// <summary>The IPA for <paramref name="text"/> in <paramref name="language"/> ("en-us", "en-gb").</summary>
    /// <remarks>Punctuation is handled by the caller; this receives runs of words. Thread safety is per engine.</remarks>
    string Phonemize(string text, string language);
}
