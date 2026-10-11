namespace Speechwarp.Voice.Espeak;

/// <summary>
/// eSpeak NG's text to phonemes (IPA), for a neural voice that needs phonemes, such as Kokoro
/// (Speechwarp.Voice.Kokoro): <c>new KokoroEngine(folder, new EspeakPhonemizer())</c> or the like.
/// </summary>
/// <remarks>
/// Thread-safe: it shares the one eSpeak (see <see cref="Espeak"/>), whose calls take turns. eSpeak NG is licensed
/// under the GPL-3.0-or-later; so is this package, and an app that uses it.
/// </remarks>
public sealed class EspeakPhonemizer : IPhonemizer
{
    /// <summary>
    /// eSpeak's IPA for <paramref name="text"/> in <paramref name="language"/> ("en-us", "en-gb"), clauses separated
    /// by a space. eSpeak's phonemes as they are: any changes a model needs (Kokoro's, for one) are the model's.
    /// </summary>
    /// <exception cref="System.ArgumentException">eSpeak has no voice <paramref name="language"/>.</exception>
    /// <exception cref="System.InvalidOperationException">eSpeak could not start (its data is missing).</exception>
    public string Phonemize(string text, string language) => Espeak.Phonemes(text, language);
}
