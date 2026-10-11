using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Speechwarp.Voice.Kokoro;

/// <summary>Where ONNX Runtime runs Kokoro.</summary>
public enum KokoroProvider
{
    /// <summary>The CPU, on every platform.</summary>
    Cpu,

    /// <summary>
    /// Apple's Core ML (the Neural Engine and GPU where the model allows, the CPU for the rest). Apple systems only;
    /// elsewhere the engine fails to load. Core ML cannot take most of Kokoro's graph, whose lengths are not fixed: on
    /// a Mac it was slower than <see cref="Cpu"/>.
    /// </summary>
    CoreML,
}

/// <summary>How a <see cref="KokoroEngine"/> loads the model. Every setting has a sensible default.</summary>
public sealed record KokoroOptions
{
    /// <summary>The model's file name in the model directory; <see cref="KokoroModels.DefaultModelFile"/> by default.</summary>
    public string ModelFile { get; init; } = KokoroModels.DefaultModelFile;

    /// <summary>CPU threads for one sentence; 0 (the default) for one a core.</summary>
    public int Threads { get; init; }

    /// <summary>Where the model runs; the CPU by default.</summary>
    public KokoroProvider Provider { get; init; } = KokoroProvider.Cpu;
}

/// <summary>
/// Kokoro-82M, a small neural text-to-speech model (af_heart and the other voices), run with ONNX Runtime. Text goes
/// to phonemes (IPA) through an <see cref="IPhonemizer"/>, as kokoro.js and kokoro-onnx do with eSpeak NG, then
/// through the model with the voice's style. 24 kHz mono.
/// </summary>
/// <remarks>
/// <para>
/// The model directory holds the model (model_fp16.onnx or another of <see cref="KokoroModels.Models"/>),
/// tokenizer.json and voices/NAME.bin; <see cref="KokoroModels"/> lists where to download them.
/// </para>
/// <para>
/// Punctuation is kept out of the phonemizer and given to the model as it is, for its phrasing; the phonemes are then
/// adjusted as kokoro.js does. Text longer than the model's 510 tokens is spoken in pieces, split between sentences
/// where it can be.
/// </para>
/// <para>
/// Thread safety: <see cref="Speak"/> and <see cref="SpeakPhonemes"/> may be called from several threads at once
/// (ONNX Runtime runs sessions concurrently, and the voice cache is shared safely) provided the phonemizer is itself
/// safe to call from several threads. Loading the model takes a second or more and about the model's size in memory,
/// so share one engine between voices rather than making one per voice. <see cref="Dispose"/> must not overlap a call.
/// </para>
/// </remarks>
public sealed partial class KokoroEngine : IDisposable
{
    /// <summary>Frames a second of what the engine returns: 24,000. Mono.</summary>
    public const int SampleRate = 24000;

    /// <summary>The most phoneme tokens the model takes at once.</summary>
    public const int MaxTokens = 510;

    private const int StyleSize = 256;

    private readonly InferenceSession session;
    private readonly IPhonemizer phonemizer;
    private readonly Dictionary<char, long> vocabulary;
    private readonly long space;
    private readonly HashSet<long> breaks;
    private readonly ConcurrentDictionary<string, float[]> voices = new();
    private bool disposed;
    private int notFinite;

    /// <summary>Loads the model in <paramref name="directory"/>.</summary>
    /// <param name="directory">Holds the model, tokenizer.json and voices/NAME.bin (see <see cref="KokoroModels"/>).</param>
    /// <param name="phonemizer">Turns runs of words into IPA, such as Speechwarp.Voice.Espeak's EspeakPhonemizer.</param>
    /// <param name="options">The model file, threads and provider; the defaults when null.</param>
    /// <exception cref="FileNotFoundException">The model or tokenizer.json is not in the directory.</exception>
    /// <exception cref="OnnxRuntimeException">ONNX Runtime could not load the model.</exception>
    public KokoroEngine(string directory, IPhonemizer phonemizer, KokoroOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(phonemizer);
        options ??= new KokoroOptions();
        if (options.Threads < 0)
            throw new ArgumentOutOfRangeException(nameof(options), "Threads must be 0 (one a core) or more.");
        Directory = directory;
        Options = options;
        this.phonemizer = phonemizer;

        var modelPath = KokoroModels.ModelPath(directory, options.ModelFile);
        var tokenizerPath = KokoroModels.TokenizerPath(directory);
        if (!File.Exists(modelPath))
            throw new FileNotFoundException("Kokoro's model is not in the model directory.", modelPath);
        if (!File.Exists(tokenizerPath))
            throw new FileNotFoundException("Kokoro's tokenizer.json is not in the model directory.", tokenizerPath);
        vocabulary = ReadVocabulary(tokenizerPath);
        space = vocabulary.TryGetValue(' ', out var id) ? id : -1;
        breaks = ".,;:!?—…".Where(vocabulary.ContainsKey).Select(c => vocabulary[c]).ToHashSet();

        using var sessionOptions = new SessionOptions
        {
            IntraOpNumThreads = options.Threads > 0 ? options.Threads : Environment.ProcessorCount,
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
        };
        if (options.Provider == KokoroProvider.CoreML)
        {
            sessionOptions.AppendExecutionProvider("CoreML", new Dictionary<string, string>
            {
                ["ModelFormat"] = "MLProgram",
                ["MLComputeUnits"] = "ALL",
            });
        }
        session = new InferenceSession(modelPath, sessionOptions);
    }

    /// <summary>The model directory given to the constructor.</summary>
    public string Directory { get; }

    /// <summary>The options the model was loaded with.</summary>
    public KokoroOptions Options { get; }

    /// <summary>How many times the model has answered with NaN and been run again (for tests and diagnostics).</summary>
    internal int NotFiniteCount => Volatile.Read(ref notFinite);

    /// <summary>
    /// Speaks <paramref name="text"/> (a sentence or a few) in <paramref name="voice"/>, such as "af_heart", at
    /// <paramref name="speed"/> (1 is the voice's own pace; about 0.5 to 2 work).
    /// </summary>
    /// <returns>Mono samples at <see cref="SampleRate"/>, -1 to 1; empty when there is nothing to say.</returns>
    /// <exception cref="FileNotFoundException">The voice's file is not in the voices folder.</exception>
    public float[] Speak(string text, string voice, float speed = 1)
    {
        ArgumentNullException.ThrowIfNull(text);
        ObjectDisposedException.ThrowIf(disposed, this);
        var style = Voice(voice);
        var language = KokoroModels.LanguageOf(voice);
        var tokens = new List<long>();
        var audio = new List<float>();
        foreach (var sentence in SentenceEnd().Split(text))
        {
            if (sentence.Trim().Length == 0)
                continue;
            var ids = Tokenize(Phonemize(sentence.Trim(), language));
            if (ids.Count == 0)
                continue;
            // Sentences go to the model together, for their phrasing, while they fit.
            if (tokens.Count > 0 && tokens.Count + 1 + ids.Count > MaxTokens)
            {
                RunAll(tokens, style, speed, audio);
                tokens.Clear();
            }
            if (tokens.Count > 0 && space >= 0)
                tokens.Add(space);
            tokens.AddRange(ids);
        }
        RunAll(tokens, style, speed, audio);
        return audio.ToArray();
    }

    /// <summary>
    /// Speaks <paramref name="phonemes"/>, IPA as <see cref="Phonemize"/> returns it, in <paramref name="voice"/>, for
    /// callers that make phonemes some other way. Characters the model does not know are left out.
    /// </summary>
    /// <returns>Mono samples at <see cref="SampleRate"/>, -1 to 1; empty when there is nothing to say.</returns>
    public float[] SpeakPhonemes(string phonemes, string voice, float speed = 1)
    {
        ArgumentNullException.ThrowIfNull(phonemes);
        ObjectDisposedException.ThrowIf(disposed, this);
        var style = Voice(voice);
        var audio = new List<float>();
        RunAll(Tokenize(phonemes), style, speed, audio);
        return audio.ToArray();
    }

    /// <summary>
    /// The phonemes the model is given for <paramref name="text"/>: the phonemizer's IPA between the punctuation,
    /// which is kept, adjusted as kokoro.js does.
    /// </summary>
    /// <param name="text">Text in <paramref name="language"/>.</param>
    /// <param name="language">"en-us", "en-gb" or another of <see cref="KokoroModels.LanguageOf"/>'s answers.</param>
    public string Phonemize(string text, string language)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(language);
        var result = new StringBuilder();
        var last = 0;
        foreach (Match punctuation in Punctuation().Matches(text))
        {
            if (punctuation.Index > last)
                result.Append(phonemizer.Phonemize(text[last..punctuation.Index], language));
            result.Append(punctuation.Value);
            last = punctuation.Index + punctuation.Length;
        }
        if (last < text.Length)
            result.Append(phonemizer.Phonemize(text[last..], language));
        return FixPhonemes(result.ToString(), language);
    }

    /// <summary>kokoro.js's adjustments to eSpeak's IPA, for the phonemes Kokoro was trained on.</summary>
    internal static string FixPhonemes(string phonemes, string language)
    {
        var ps = phonemes
            .Replace("kəkˈoːɹoʊ", "kˈoʊkəɹoʊ")
            .Replace("kəkˈɔːɹoʊ", "kˈoʊkəɹoʊ") // eSpeak NG 1.52's American "Kokoro"
            .Replace("kəkˈɔːɹəʊ", "kˈəʊkəɹəʊ")
            .Replace("ʲ", "j")
            .Replace("r", "ɹ")
            .Replace("x", "k")
            .Replace("ɬ", "l");
        ps = Hundred().Replace(ps, " ");
        ps = LoneZ().Replace(ps, "z");
        if (language == "en-us")
            ps = Ninety().Replace(ps, "di");
        return ps.Trim();
    }

    /// <summary>The model's token ids for <paramref name="phonemes"/>; characters it does not know are left out.</summary>
    internal List<long> Tokenize(string phonemes)
    {
        var ids = new List<long>(phonemes.Length);
        foreach (var c in phonemes)
        {
            if (vocabulary.TryGetValue(c, out var id))
                ids.Add(id);
        }
        return ids;
    }

    /// <summary>Runs the model on <paramref name="tokens"/>, in pieces of at most <see cref="MaxTokens"/>.</summary>
    private void RunAll(List<long> tokens, float[] style, float speed, List<float> audio)
    {
        var start = 0;
        while (start < tokens.Count)
        {
            var count = PieceLength(tokens, start);
            audio.AddRange(RunFinite(tokens.GetRange(start, count), style, speed, 0));
            start += count;
        }
    }

    /// <summary>
    /// Runs the model, and when its answer is not all numbers runs it again differently: the half-precision model
    /// (model_fp16) on ONNX Runtime's CPU gives NaN for the whole of some inputs (about one in five of the lengths
    /// tried), depending on the exact tokens; the full-precision and q8f16 models did not. A space added at the end
    /// mends most; the rest are split in two near the middle, at punctuation or a space. Whatever still fails is
    /// returned as silence, so callers never get NaN.
    /// </summary>
    private float[] RunFinite(List<long> ids, float[] style, float speed, int depth)
    {
        var audio = Run(ids, style, speed);
        if (IsFinite(audio))
            return audio;
        Interlocked.Increment(ref notFinite);
        if (space >= 0 && (ids.Count == 0 || ids[^1] != space) && ids.Count < MaxTokens)
        {
            audio = Run([.. ids, space], style, speed);
            if (IsFinite(audio))
                return audio;
        }
        var middle = depth < 4 ? SplitPoint(ids) : -1;
        if (middle > 0)
        {
            var first = RunFinite(ids.GetRange(0, middle), style, speed, depth + 1);
            var second = RunFinite(ids.GetRange(middle, ids.Count - middle), style, speed, depth + 1);
            return [.. first, .. second];
        }
        for (var i = 0; i < audio.Length; i++)
        {
            if (!float.IsFinite(audio[i]))
                audio[i] = 0;
        }
        return audio;
    }

    private static bool IsFinite(float[] audio)
    {
        foreach (var sample in audio)
        {
            if (!float.IsFinite(sample))
                return false;
        }
        return true;
    }

    /// <summary>
    /// Where to cut <paramref name="ids"/> in two: after the punctuation nearest the middle, or failing that the space
    /// nearest it; -1 when there is neither, or the run is too short to be worth cutting.
    /// </summary>
    private int SplitPoint(List<long> ids)
    {
        if (ids.Count < 8)
            return -1;
        int best = -1, bestSpace = -1;
        for (var i = 2; i < ids.Count - 2; i++)
        {
            var distance = Math.Abs(i - ids.Count / 2);
            if (breaks.Contains(ids[i]) && (best < 0 || distance < Math.Abs(best - ids.Count / 2)))
                best = i;
            if (ids[i] == space && (bestSpace < 0 || distance < Math.Abs(bestSpace - ids.Count / 2)))
                bestSpace = i;
        }
        var cut = best >= 0 ? best : bestSpace;
        return cut >= 0 ? cut + 1 : -1;
    }

    /// <summary>
    /// How many tokens from <paramref name="start"/> go to the model together: all that are left if they fit, or else
    /// up to the last punctuation, or failing that the last space, within <see cref="MaxTokens"/>.
    /// </summary>
    private int PieceLength(List<long> tokens, int start)
    {
        var left = tokens.Count - start;
        if (left <= MaxTokens)
            return left;
        int lastPunctuation = -1, lastSpace = -1;
        for (var i = start + MaxTokens - 1; i > start; i--)
        {
            if (lastPunctuation < 0 && breaks.Contains(tokens[i]))
                lastPunctuation = i;
            if (lastSpace < 0 && tokens[i] == space)
                lastSpace = i;
            if (lastPunctuation >= 0)
                break;
        }
        var end = lastPunctuation >= 0 ? lastPunctuation : lastSpace;
        return end > start ? end - start + 1 : MaxTokens;
    }

    private float[] Run(List<long> ids, float[] style, float speed)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (ids.Count == 0)
            return [];
        // The model expects the ids between two padding tokens (0); the style row is chosen by the length.
        var input = new DenseTensor<long>([1, ids.Count + 2]);
        for (var i = 0; i < ids.Count; i++)
            input[0, i + 1] = ids[i];
        var rows = style.Length / StyleSize;
        var row = Math.Min(ids.Count, rows - 1);
        var styleTensor = new DenseTensor<float>(style.AsMemory(row * StyleSize, StyleSize), [1, StyleSize]);
        using var results = session.Run(
        [
            NamedOnnxValue.CreateFromTensor("input_ids", input),
            NamedOnnxValue.CreateFromTensor("style", styleTensor),
            NamedOnnxValue.CreateFromTensor("speed", new DenseTensor<float>(new[] { speed }, [1])),
        ]);
        return results[0].AsTensor<float>().ToArray();
    }

    /// <summary>The style vectors of <paramref name="name"/>, read from voices/NAME.bin the first time.</summary>
    private float[] Voice(string name)
    {
        KokoroModels.CheckVoiceName(name);
        return voices.GetOrAdd(name, static (voice, directory) =>
        {
            var path = KokoroModels.VoicePath(directory, voice);
            if (!File.Exists(path))
                throw new FileNotFoundException($"Kokoro's voice {voice} is not in the voices folder.", path);
            var bytes = File.ReadAllBytes(path);
            if (bytes.Length < StyleSize * sizeof(float) || bytes.Length % (StyleSize * sizeof(float)) != 0)
                throw new InvalidDataException($"{path} is not a Kokoro voice file (rows of {StyleSize} floats).");
            return MemoryMarshal.Cast<byte, float>(bytes).ToArray();
        }, Directory);
    }

    private static Dictionary<char, long> ReadVocabulary(string path)
    {
        using var tokenizer = JsonDocument.Parse(File.ReadAllText(path));
        return tokenizer.RootElement.GetProperty("model").GetProperty("vocab").EnumerateObject()
            .Where(p => p.Name.Length == 1)
            .ToDictionary(p => p.Name[0], p => (long)p.Value.GetInt32());
    }

    /// <summary>Frees the model. The engine cannot be used afterwards.</summary>
    public void Dispose()
    {
        if (disposed)
            return;
        disposed = true;
        session.Dispose();
    }

    [GeneratedRegex(@"(?<=[.!?…])\s+|\n{2,}")]
    private static partial Regex SentenceEnd();

    [GeneratedRegex(@"(\s*[;:,.!?¡¿—…""«»“”(){}\[\]]+\s*)+")]
    private static partial Regex Punctuation();

    [GeneratedRegex(@"(?<=[a-zɹː])(?=hˈʌndɹɪd)")]
    private static partial Regex Hundred();

    [GeneratedRegex(@" z(?=[;:,.!?¡¿—…""«»“” ]|$)")]
    private static partial Regex LoneZ();

    [GeneratedRegex(@"(?<=nˈaɪn)ti(?!ː)")]
    private static partial Regex Ninety();
}
