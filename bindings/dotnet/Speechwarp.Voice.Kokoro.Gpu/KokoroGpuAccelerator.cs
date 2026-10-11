using System;

namespace Speechwarp.Voice.Kokoro.Gpu;

/// <summary>
/// Kokoro on the GPU as an <see cref="IKokoroAccelerator"/> for <see cref="KokoroSentenceVoice"/>: each sentence is
/// spoken on the GPU when <see cref="KokoroGpu.IsAvailable"/> says it can be, and otherwise left to ONNX Runtime on the
/// CPU. The CPU engine is loaded only when a sentence first needs it.
/// </summary>
/// <example>
/// <code>
/// // At launch, on the main thread:
/// KokoroGpu.WatchAppState();
///
/// // Then, for a voice (the model directory holds the CPU files, kokoro-v1_0.safetensors and, to opt in, use-gpu):
/// var gpu = new KokoroGpuAccelerator(directory);
/// using var voice = new KokoroSentenceVoice(directory, "af_heart", new EspeakPhonemizer(), accelerator: gpu);
/// float[] samples = voice.Speak("Hello there.");   // 24 kHz mono, from the GPU while the app is on screen
/// </code>
/// </example>
/// <remarks>
/// <para>
/// The GPU makes its own phonemes with misaki, so it pronounces a few words differently from the CPU's phonemizer; both
/// are the same voice and keep the same cache id. Only English voices (American a*, British b*) use the GPU.
/// </para>
/// <para>
/// A failure on the GPU (the model will not load, a sentence fails) is reported to <see cref="KokoroGpu.Log"/> and that
/// sentence goes to the CPU; after <see cref="MaxFailures"/> failures in a row this accelerator stops trying, so a broken
/// GPU path costs a player nothing but the first attempts.
/// </para>
/// </remarks>
public sealed class KokoroGpuAccelerator : IKokoroAccelerator
{
    private readonly object _lock = new();
    private int _failures;

    /// <summary>An accelerator using the model in <paramref name="directory"/>, the same model directory as the CPU's.</summary>
    public KokoroGpuAccelerator(string directory)
    {
        ArgumentNullException.ThrowIfNull(directory);
        Directory = directory;
    }

    /// <summary>The model directory.</summary>
    public string Directory { get; }

    /// <summary>Failures in a row after which this accelerator leaves everything to the CPU. Default 3.</summary>
    public int MaxFailures { get; init; } = 3;

    /// <summary>The most recent failure on the GPU, if any; null after a sentence succeeds.</summary>
    public Exception? LastError { get; private set; }

    /// <summary>Too many failures in a row: this accelerator no longer tries the GPU.</summary>
    public bool HasGivenUp
    {
        get
        {
            lock (_lock)
                return _failures >= MaxFailures;
        }
    }

    /// <summary>
    /// Speaks <paramref name="text"/> on the GPU, or returns null to leave it to the CPU: the GPU is not available now
    /// (see <see cref="KokoroGpu.IsAvailable"/>), the voice is not English, or speaking failed.
    /// </summary>
    /// <param name="text">The text, not phonemes.</param>
    /// <param name="voice">The voice's name, such as "af_heart".</param>
    /// <param name="voiceFile">The voice's style file, voices/NAME.bin.</param>
    /// <param name="language">"en-us" or "en-gb"; any other language returns null.</param>
    /// <param name="speed">1 for the voice's own pace.</param>
    /// <returns>Mono samples at 24 kHz, -1 to 1, or null.</returns>
    public float[]? TrySpeak(string text, string voice, string voiceFile, string language, float speed)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(voiceFile);
        ArgumentNullException.ThrowIfNull(language);
        var british = language.Equals("en-gb", StringComparison.OrdinalIgnoreCase);
        if (!british && !language.Equals("en-us", StringComparison.OrdinalIgnoreCase))
            return null;
        if (HasGivenUp || !KokoroGpu.IsAvailable(Directory))
            return null;
        try
        {
            var samples = KokoroGpu.Speak(Directory, voiceFile, text, british, speed);
            lock (_lock)
                _failures = 0;
            LastError = null;
            return samples;
        }
        catch (GpuUnavailableException)
        {
            return null;
        }
        catch (InvalidOperationException ex)
        {
            LastError = ex;
            lock (_lock)
                _failures++;
            return null;
        }
    }
}
