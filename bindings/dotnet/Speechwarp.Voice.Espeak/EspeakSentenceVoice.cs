using System;

namespace Speechwarp.Voice.Espeak;

/// <summary>
/// eSpeak NG's formant voice in one language or accent, as a sentence voice for the live reader and the cache of
/// Speechwarp.Voice. Quick enough to speak as it is heard, so nothing needs keeping.
/// </summary>
/// <remarks>
/// Every instance shares the one eSpeak (see <see cref="Espeak"/>), whose calls take turns. eSpeak NG is licensed
/// under the GPL-3.0-or-later; so is this package, and an app that uses it.
/// </remarks>
public sealed class EspeakSentenceVoice : ISentenceVoice
{
    /// <summary>
    /// A voice for <paramref name="language"/>, such as "en-us", "en-gb", "en-gb-x-rp" or "en-us+klatt" (see
    /// <see cref="Espeak.Voices"/> and <see cref="Espeak.Variants"/>), at a rate and pitch.
    /// </summary>
    /// <param name="language">The voice, as <see cref="Espeak.Speak"/> takes it.</param>
    /// <param name="wordsPerMinute">Speaking rate, 80 to 450.</param>
    /// <param name="pitch">Pitch, 0 to 100.</param>
    /// <exception cref="InvalidOperationException">eSpeak could not start (its data is missing).</exception>
    public EspeakSentenceVoice(string language = "en-us", int wordsPerMinute = Espeak.DefaultWordsPerMinute,
        int pitch = Espeak.DefaultPitch)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(language);
        Language = language;
        WordsPerMinute = wordsPerMinute;
        Pitch = pitch;
        SampleRate = Espeak.SampleRate;
    }

    /// <summary>The voice, such as "en-gb".</summary>
    public string Language { get; }

    /// <summary>Speaking rate in words a minute.</summary>
    public int WordsPerMinute { get; }

    /// <summary>Pitch, 0 to 100.</summary>
    public int Pitch { get; }

    /// <summary>
    /// "espeak:" and the language, such as "espeak:en-gb"; at a rate or pitch other than the defaults, these follow,
    /// as in "espeak:en-gb/220/50", so that cached audio is never taken for another rate's.
    /// </summary>
    public string Id => WordsPerMinute == Espeak.DefaultWordsPerMinute && Pitch == Espeak.DefaultPitch
        ? "espeak:" + Language
        : $"espeak:{Language}/{WordsPerMinute}/{Pitch}";

    /// <inheritdoc />
    public int SampleRate { get; }

    /// <inheritdoc />
    /// <exception cref="ArgumentException">eSpeak has no voice <see cref="Language"/>.</exception>
    public float[] Speak(string sentence) => Espeak.Speak(sentence, Language, WordsPerMinute, Pitch);

    /// <summary>Nothing to release: eSpeak stays loaded for the life of the app.</summary>
    public void Dispose()
    {
    }
}
