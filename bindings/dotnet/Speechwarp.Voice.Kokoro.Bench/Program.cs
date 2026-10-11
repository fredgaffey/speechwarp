// How fast Kokoro speaks on this machine: the desktop version of KokoroBenchmark, which an app runs on a phone.
//
//   dotnet run -c Release -- MODEL_DIR [TEXT_FILE] [--seconds 60] [--voice af_heart] [--model model_fp16.onnx]
//                                       [--threads 0] [--provider cpu|coreml] [--parallel 1] [--wav out.wav]
//
// Phonemes come from the espeak-ng command, which must be on the PATH (brew install espeak-ng). Without a text file
// it speaks a few built-in paragraphs. --wav writes the first paragraph to a WAV file to listen to.

using System.Globalization;
using Speechwarp.Voice.Kokoro;
using Speechwarp.Voice.Kokoro.Bench;

var positional = new List<string>();
var named = new Dictionary<string, string>();
for (var i = 0; i < args.Length; i++)
{
    if (args[i].StartsWith("--", StringComparison.Ordinal) && i + 1 < args.Length)
        named[args[i][2..]] = args[++i];
    else
        positional.Add(args[i]);
}
if (positional.Count == 0)
{
    Console.Error.WriteLine("Usage: Speechwarp.Voice.Kokoro.Bench MODEL_DIR [TEXT_FILE] [--seconds 60] [--voice af_heart] "
        + "[--model model_fp16.onnx] [--threads 0] [--provider cpu|coreml] [--parallel 1] [--wav out.wav]");
    return 2;
}
if (!EspeakCommandPhonemizer.IsAvailable())
{
    Console.Error.WriteLine("espeak-ng is not on the PATH; install it (brew install espeak-ng).");
    return 1;
}

var directory = positional[0];
var text = positional.Count > 1 ? File.ReadAllText(positional[1]) : string.Join("\n\n",
    "The sun had not yet risen over the hills when the travellers set out, and the road was grey and quiet.",
    "Nobody spoke for the first mile. Each of them was thinking of what lay ahead, and of what they had left behind.",
    "By nine o'clock the mist had lifted, and they could see the river below them, wide and slow, shining like a ribbon.",
    "\"We'll stop at the bridge,\" said Anna, \"and not a moment before.\" The others laughed, but they did not argue.",
    "In 1924 the bridge had been the longest in the county: three hundred and twelve feet of iron and stone.");
string Get(string name, string fallback) => named.TryGetValue(name, out var value) ? value : fallback;
var voice = Get("voice", KokoroModels.DefaultVoice);
var options = new KokoroOptions
{
    ModelFile = Get("model", KokoroModels.DefaultModelFile),
    Threads = int.Parse(Get("threads", "0"), CultureInfo.InvariantCulture),
    Provider = Get("provider", "cpu").Equals("coreml", StringComparison.OrdinalIgnoreCase) ? KokoroProvider.CoreML : KokoroProvider.Cpu,
};
var phonemizer = new EspeakCommandPhonemizer();

if (named.TryGetValue("wav", out var wav))
{
    using var engine = new KokoroEngine(directory, phonemizer, options);
    var first = text.Split("\n\n", StringSplitOptions.RemoveEmptyEntries)[0];
    Console.WriteLine($"Phonemes: {engine.Phonemize(first, KokoroModels.LanguageOf(voice))}");
    WriteWav(wav, engine.Speak(first, voice), KokoroEngine.SampleRate);
    Console.WriteLine($"Wrote {wav}");
}

var result = KokoroBenchmark.Run(directory, phonemizer, text, voice, options,
    TimeSpan.FromSeconds(double.Parse(Get("seconds", "60"), CultureInfo.InvariantCulture)),
    int.Parse(Get("parallel", "1"), CultureInfo.InvariantCulture));
Console.WriteLine($"{options.ModelFile}, {voice}, {options.Provider}, {(options.Threads > 0 ? options.Threads : Environment.ProcessorCount)} threads, "
    + $"{result.Engines} at once: loaded in {result.LoadSeconds:0.00} s");
Console.WriteLine($"{result.Paragraphs} paragraphs, {result.AudioSeconds:0.0} s of audio in {result.ElapsedSeconds:0.0} s: "
    + $"real-time factor {result.RealTimeFactor:0.000} ({result.TimesRealTime:0.0}x real time)");
return 0;

static void WriteWav(string path, float[] samples, int sampleRate)
{
    using var writer = new BinaryWriter(File.Create(path));
    writer.Write("RIFF"u8);
    writer.Write(36 + samples.Length * 2);
    writer.Write("WAVEfmt "u8);
    writer.Write(16);
    writer.Write((short)1);
    writer.Write((short)1);
    writer.Write(sampleRate);
    writer.Write(sampleRate * 2);
    writer.Write((short)2);
    writer.Write((short)16);
    writer.Write("data"u8);
    writer.Write(samples.Length * 2);
    foreach (var sample in samples)
        writer.Write((short)Math.Round(Math.Clamp(sample, -1f, 1f) * 32767));
}
