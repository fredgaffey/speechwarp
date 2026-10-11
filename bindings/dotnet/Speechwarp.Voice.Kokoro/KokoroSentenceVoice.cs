using System;
using System.Globalization;
using System.Threading;

namespace Speechwarp.Voice.Kokoro;

/// <summary>
/// Another way to run Kokoro, tried before ONNX Runtime: Speechwarp.Voice.Kokoro.Gpu supplies one that runs on Apple
/// GPUs through MLX. It can decline any sentence, and the CPU speaks that one instead.
/// </summary>
/// <remarks>Called from the same threads as <see cref="ISentenceVoice.Speak"/>; an implementation serialises what it must.</remarks>
public interface IKokoroAccelerator
{
    /// <summary>
    /// Speaks <paramref name="text"/> in <paramref name="voice"/>, or returns null when it cannot just now (the app
    /// is in the background, the model is not downloaded): then ONNX Runtime speaks it. Throws only for a real failure.
    /// </summary>
    /// <param name="text">The text, not phonemes: an accelerator makes its own.</param>
    /// <param name="voice">The voice's name, such as "af_heart".</param>
    /// <param name="voiceFile">The voice's style file, voices/NAME.bin in the model directory.</param>
    /// <param name="language">The voice's language, as <see cref="KokoroModels.LanguageOf"/> says ("en-us", "en-gb").</param>
    /// <param name="speed">1 for the voice's own pace.</param>
    /// <returns>Mono samples at 24 kHz, -1 to 1, or null to leave the sentence to the CPU.</returns>
    float[]? TrySpeak(string text, string voice, string voiceFile, string language, float speed);
}

/// <summary>
/// A Kokoro voice as an <see cref="ISentenceVoice"/>, for the live reader and the voice cache: id "kokoro:NAME",
/// 24 kHz, and kept on disk (<see cref="KeepsSpoken"/>), because a phone speaks it little faster than it is heard.
/// </summary>
/// <remarks>
/// Each sentence goes to the accelerator first, when there is one, and otherwise (or when it declines) to a
/// <see cref="KokoroEngine"/> on ONNX Runtime. The engine is loaded when it is first needed, not by the constructor.
/// Several voices can share one engine (the model is the large part) through the constructor that takes one.
/// </remarks>
public sealed class KokoroSentenceVoice : ISentenceVoice
{
    private readonly Lazy<KokoroEngine> engine;
    private readonly bool ownsEngine;
    private readonly IKokoroAccelerator? accelerator;
    private readonly string language;
    private readonly string voiceFile;

    /// <summary>A voice with its own engine, loaded from <paramref name="directory"/> when first needed.</summary>
    /// <param name="directory">The model directory (see <see cref="KokoroModels"/>).</param>
    /// <param name="voice">The voice's name, such as "af_heart".</param>
    /// <param name="phonemizer">Turns words into IPA, such as Speechwarp.Voice.Espeak's EspeakPhonemizer.</param>
    /// <param name="options">How the engine loads the model; the defaults when null.</param>
    /// <param name="accelerator">Tried before the engine for each sentence, such as Speechwarp.Voice.Kokoro.Gpu's; none when null.</param>
    public KokoroSentenceVoice(string directory, string voice, IPhonemizer phonemizer, KokoroOptions? options = null,
        IKokoroAccelerator? accelerator = null)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(phonemizer);
        KokoroModels.CheckVoiceName(voice);
        engine = new Lazy<KokoroEngine>(() => new KokoroEngine(directory, phonemizer, options),
            LazyThreadSafetyMode.ExecutionAndPublication);
        ownsEngine = true;
        Directory = directory;
        Voice = voice;
        this.accelerator = accelerator;
        language = KokoroModels.LanguageOf(voice);
        voiceFile = KokoroModels.VoicePath(directory, voice);
    }

    /// <summary>A voice that speaks with <paramref name="engine"/>, which the caller keeps and disposes.</summary>
    /// <param name="engine">A loaded engine, perhaps shared with other voices.</param>
    /// <param name="voice">The voice's name, such as "af_heart".</param>
    /// <param name="accelerator">Tried before the engine for each sentence; none when null.</param>
    public KokoroSentenceVoice(KokoroEngine engine, string voice, IKokoroAccelerator? accelerator = null)
    {
        ArgumentNullException.ThrowIfNull(engine);
        KokoroModels.CheckVoiceName(voice);
        this.engine = new Lazy<KokoroEngine>(engine);
        ownsEngine = false;
        Directory = engine.Directory;
        Voice = voice;
        this.accelerator = accelerator;
        language = KokoroModels.LanguageOf(voice);
        voiceFile = KokoroModels.VoicePath(engine.Directory, voice);
    }

    /// <summary>The model directory.</summary>
    public string Directory { get; }

    /// <summary>The voice's name, such as "af_heart".</summary>
    public string Voice { get; }

    /// <summary>The pace, 1 for the voice's own (about 0.5 to 2 work). Any other pace is part of <see cref="Id"/>.</summary>
    public float Speed { get; init; } = 1;

    /// <summary>
    /// "kokoro:" and the voice's name, such as "kokoro:af_heart"; at a pace other than 1, "/" and the pace follow
    /// ("kokoro:af_heart/1.2"), so that audio kept at one pace is never served for another.
    /// </summary>
    public string Id => Speed == 1 ? "kokoro:" + Voice : "kokoro:" + Voice + "/" + Speed.ToString("0.###", CultureInfo.InvariantCulture);

    /// <summary>24,000 (<see cref="KokoroEngine.SampleRate"/>).</summary>
    public int SampleRate => KokoroEngine.SampleRate;

    /// <summary>True: Kokoro on a phone is slow enough that what it speaks is worth keeping.</summary>
    public bool KeepsSpoken => true;

    /// <summary>Speaks <paramref name="sentence"/>: on the accelerator if it takes it, otherwise on ONNX Runtime.</summary>
    /// <returns>Mono samples at 24 kHz, -1 to 1; empty when there is nothing to say.</returns>
    public float[] Speak(string sentence)
    {
        ArgumentNullException.ThrowIfNull(sentence);
        if (sentence.Trim().Length == 0)
            return [];
        if (accelerator?.TrySpeak(sentence, Voice, voiceFile, language, Speed) is { } accelerated)
            return accelerated;
        return engine.Value.Speak(sentence, Voice, Speed);
    }

    /// <summary>Frees the engine if this voice loaded it; a shared engine is left to its owner.</summary>
    public void Dispose()
    {
        if (ownsEngine && engine.IsValueCreated)
            engine.Value.Dispose();
    }
}
