using System.Text.RegularExpressions;
using Speechwarp.Listen;
using Speechwarp.Voice.Kokoro.Bench;

namespace Speechwarp.Voice.Kokoro.Tests;

/// <summary>
/// Tests of Speechwarp.Voice.Kokoro. Those that run the model need a model directory (model_fp16.onnx,
/// tokenizer.json, voices/af_heart.bin and voices/bf_emma.bin; see KokoroModels) named by the environment variable
/// SPEECHWARP_KOKORO_DIR, and are skipped without one. Those that phonemize real text need the espeak-ng command on
/// the PATH. The one that checks the words also needs a whisper.cpp model named by SPEECHWARP_LISTEN_MODEL.
/// </summary>
[TestClass]
public class KokoroTests
{
    /// <summary>"Hello world, this is Kokoro speaking." in eSpeak NG's American IPA, after kokoro.js's adjustments.</summary>
    private const string HelloPhonemes = "həlˈoʊ wˈɜːld, ðɪs ɪz kˈoʊkəɹoʊ spˈiːkɪŋ.";

    private static string ModelDirectory()
    {
        var directory = Environment.GetEnvironmentVariable("SPEECHWARP_KOKORO_DIR");
        if (string.IsNullOrEmpty(directory))
            Assert.Inconclusive("Set SPEECHWARP_KOKORO_DIR to a Kokoro model directory to run this test.");
        Assert.IsTrue(KokoroModels.IsInstalled(directory, "af_heart"), $"SPEECHWARP_KOKORO_DIR has no model with af_heart: {directory}");
        return directory;
    }

    private static IPhonemizer Espeak()
    {
        if (!EspeakCommandPhonemizer.IsAvailable())
            Assert.Inconclusive("The espeak-ng command is not on the PATH.");
        return new EspeakCommandPhonemizer();
    }

    private static double Rms(float[] samples) => Math.Sqrt(samples.Average(s => (double)s * s));

    private static string Plain(string text) =>
        Regex.Replace(Regex.Replace(text.ToLowerInvariant(), @"[^a-z0-9' ]", " "), @"\s+", " ").Trim();

    /// <summary>Gives back its input in brackets, and records what it was asked.</summary>
    private sealed class StubPhonemizer : IPhonemizer
    {
        public List<(string Text, string Language)> Calls { get; } = [];

        public string Phonemize(string text, string language)
        {
            lock (Calls)
                Calls.Add((text, language));
            return text.Trim().ToLowerInvariant();
        }
    }

    private sealed class FakeAccelerator(float[]? answer) : IKokoroAccelerator
    {
        public List<(string Text, string Voice, string VoiceFile, string Language, float Speed)> Calls { get; } = [];

        public float[]? TrySpeak(string text, string voice, string voiceFile, string language, float speed)
        {
            Calls.Add((text, voice, voiceFile, language, speed));
            return answer;
        }
    }

    // The catalogue.

    [TestMethod]
    public void CatalogueListsEveryModelAndVoiceWithHashes()
    {
        Assert.HasCount(8, KokoroModels.Models);
        Assert.AreEqual(KokoroModels.DefaultModelFile, KokoroModels.Models[0].File.RelativePath);
        Assert.HasCount(54, KokoroModels.Voices);
        var files = KokoroModels.Models.Select(m => m.File).Concat(KokoroModels.Voices.Select(v => v.File)).Append(KokoroModels.Tokenizer).ToList();
        foreach (var file in files)
        {
            Assert.MatchesRegex("^[0-9a-f]{64}$", file.Sha256, file.RelativePath);
            Assert.IsGreaterThan(0L, file.SizeBytes);
            StringAssert.StartsWith(file.Url, $"https://huggingface.co/{KokoroModels.Repository}/resolve/{KokoroModels.Revision}/");
        }
        Assert.AreEqual(files.Count, files.Select(f => f.RelativePath).Distinct().Count());
        StringAssert.EndsWith(KokoroModels.Models[0].File.Url, "/onnx/model_fp16.onnx");
        Assert.AreEqual("voices/af_heart.bin", KokoroModels.FindVoice("af_heart")!.File.RelativePath);
        Assert.AreEqual("model_q8f16", KokoroModels.FindModel("model_q8f16.onnx")!.Id);
        Assert.IsNull(KokoroModels.FindVoice("nobody"));
    }

    [TestMethod]
    public void VoiceNamesGiveLanguageAndGender()
    {
        Assert.AreEqual("en-us", KokoroModels.LanguageOf("af_heart"));
        Assert.AreEqual("en-gb", KokoroModels.LanguageOf("bm_george"));
        Assert.AreEqual("fr-fr", KokoroModels.LanguageOf("ff_siwis"));
        Assert.IsTrue(KokoroModels.FindVoice("bf_emma")!.IsFemale);
        Assert.IsFalse(KokoroModels.FindVoice("am_adam")!.IsFemale);
        Assert.AreEqual("en-gb", KokoroModels.FindVoice("bf_emma")!.Language);
    }

    [TestMethod]
    public void VoicePathRefusesAnythingButAName()
    {
        Assert.AreEqual(Path.Combine("dir", "voices", "af_heart.bin"), KokoroModels.VoicePath("dir", "af_heart"));
        Assert.ThrowsExactly<ArgumentException>(() => KokoroModels.VoicePath("dir", "../secret"));
        Assert.ThrowsExactly<ArgumentException>(() => KokoroModels.VoicePath("dir", ""));
        Assert.IsFalse(KokoroModels.IsInstalled("dir", "../af_heart"));
    }

    [TestMethod]
    public void IsInstalledChecksEveryFileAndItsSize()
    {
        var directory = Directory.CreateTempSubdirectory("kokoro-test").FullName;
        try
        {
            Assert.IsFalse(KokoroModels.IsInstalled(directory, "af_heart", "mine.onnx"));
            Assert.HasCount(3, KokoroModels.MissingFiles(directory, "af_heart"));
            // A model not in the catalogue may be any size; the catalogue's files must be theirs.
            File.WriteAllBytes(Path.Combine(directory, "mine.onnx"), [1]);
            File.WriteAllBytes(KokoroModels.TokenizerPath(directory), new byte[KokoroModels.Tokenizer.SizeBytes]);
            Directory.CreateDirectory(Path.Combine(directory, "voices"));
            File.WriteAllBytes(KokoroModels.VoicePath(directory, "af_heart"), new byte[100]);
            Assert.IsFalse(KokoroModels.IsInstalled(directory, "af_heart", "mine.onnx"), "a voice cut short");
            File.WriteAllBytes(KokoroModels.VoicePath(directory, "af_heart"), new byte[KokoroModels.FindVoice("af_heart")!.File.SizeBytes]);
            Assert.IsTrue(KokoroModels.IsInstalled(directory, "af_heart", "mine.onnx"));
            Assert.IsFalse(KokoroModels.IsInstalled(directory, "bf_emma", "mine.onnx"));
            CollectionAssert.AreEqual(new[] { "model_fp16.onnx" },
                KokoroModels.MissingFiles(directory, "af_heart").Select(f => f.RelativePath).ToArray());
            Assert.ThrowsExactly<ArgumentException>(() => KokoroModels.MissingFiles(directory, "af_heart", "mine.onnx"));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    // Phonemes.

    [TestMethod]
    public void PhonemeFixesFollowKokoroJs()
    {
        Assert.AreEqual("ɹɛd ɹʌn", KokoroEngine.FixPhonemes("rɛd rʌn", "en-us"));
        Assert.AreEqual("lɔk", KokoroEngine.FixPhonemes("lɔx", "en-gb"));
        Assert.AreEqual("kjuː", KokoroEngine.FixPhonemes("kʲuː", "en-us"));
        Assert.AreEqual("wˈʌn hˈʌndɹɪd", KokoroEngine.FixPhonemes("wˈʌnhˈʌndɹɪd", "en-us"));
        Assert.AreEqual("dˈɔɡz.", KokoroEngine.FixPhonemes("dˈɔɡ z.", "en-us"));
        Assert.AreEqual("nˈaɪndi", KokoroEngine.FixPhonemes("nˈaɪnti", "en-us"));
        Assert.AreEqual("nˈaɪnti", KokoroEngine.FixPhonemes("nˈaɪnti", "en-gb"), "only American English");
        Assert.AreEqual("kˈoʊkəɹoʊ", KokoroEngine.FixPhonemes("kəkˈoːɹoʊ", "en-us"));
        Assert.AreEqual("kˈoʊkəɹoʊ", KokoroEngine.FixPhonemes("kəkˈɔːɹoʊ", "en-us"), "eSpeak NG 1.52's Kokoro");
    }

    // The engine with a model.

    [TestMethod]
    public void PunctuationIsKeptOutOfThePhonemizer()
    {
        var stub = new StubPhonemizer();
        using var engine = new KokoroEngine(ModelDirectory(), stub);
        Assert.AreEqual("hello, you! how do you do?", engine.Phonemize("Hello, you! How do you do?", "en-gb"));
        CollectionAssert.AreEqual(new[] { "Hello", "you", "How do you do" }, stub.Calls.Select(c => c.Text).ToArray());
        Assert.IsTrue(stub.Calls.All(c => c.Language == "en-gb"));
    }

    [TestMethod]
    public void SpeaksKnownPhonemes()
    {
        using var engine = new KokoroEngine(ModelDirectory(), new StubPhonemizer());
        var audio = engine.SpeakPhonemes(HelloPhonemes, "af_heart");
        var seconds = audio.Length / (double)KokoroEngine.SampleRate;
        Assert.IsTrue(seconds is > 1.2 and < 4.5, $"{seconds:0.00} s of audio");
        Assert.IsGreaterThan(0.02, Rms(audio), "speech, not silence");
        Assert.IsLessThanOrEqualTo(1.5f, audio.Max(s => Math.Abs(s)), "no wild samples");
        Assert.IsTrue(audio.All(float.IsFinite));

        var slower = engine.SpeakPhonemes(HelloPhonemes, "af_heart", 0.7f);
        Assert.IsGreaterThan((int)(audio.Length * 1.2), slower.Length, "speed 0.7 is slower");
        Assert.IsEmpty(engine.SpeakPhonemes("", "af_heart"));
        Assert.IsEmpty(engine.Speak("  ", "af_heart"));
    }

    [TestMethod]
    public void MissingVoiceSaysSo()
    {
        using var engine = new KokoroEngine(ModelDirectory(), new StubPhonemizer());
        Assert.ThrowsExactly<FileNotFoundException>(() => engine.SpeakPhonemes(HelloPhonemes, "zz_nobody"));
        Assert.ThrowsExactly<ArgumentException>(() => engine.SpeakPhonemes(HelloPhonemes, "../af_heart"));
    }

    [TestMethod]
    public void MissingModelSaysSo()
    {
        var directory = Directory.CreateTempSubdirectory("kokoro-test").FullName;
        try
        {
            Assert.ThrowsExactly<FileNotFoundException>(() => new KokoroEngine(directory, new StubPhonemizer()));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [TestMethod]
    public void SpeaksTextThroughThePhonemizer()
    {
        using var engine = new KokoroEngine(ModelDirectory(), Espeak());
        Assert.AreEqual(HelloPhonemes, engine.Phonemize("Hello world, this is Kokoro speaking.", "en-us"));
        var audio = engine.Speak("Hello world, this is Kokoro speaking.", "af_heart");
        Assert.IsTrue(audio.Length / (double)KokoroEngine.SampleRate is > 1.2 and < 4.5);
        Assert.IsGreaterThan(0.02, Rms(audio));
        var british = engine.Speak("Hello world, this is Kokoro speaking.", "bf_emma");
        Assert.IsGreaterThan(0.02, Rms(british));
    }

    [TestMethod]
    public void LongTextIsSpokenInPieces()
    {
        var stub = new StubPhonemizer();
        using var engine = new KokoroEngine(ModelDirectory(), stub);
        // 16 sentences of about 55 tokens, far over 510 in all.
        var sentence = "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ.";
        var one = engine.Speak(sentence, "af_heart");
        var many = engine.Speak(string.Join(" ", Enumerable.Repeat(sentence, 16)), "af_heart");
        var ratio = many.Length / (double)one.Length;
        Assert.IsTrue(ratio is > 11 and < 22, $"16 sentences gave {ratio:0.0} times one sentence's audio");
        // One run of more than 510 tokens with no sentence end is cut, not truncated.
        var run = string.Join(", ", Enumerable.Repeat("ðə kwˈɪk bɹˈaʊn fˈɑːks", 40));
        Assert.IsGreaterThan(MaxTokensWorth(engine), engine.SpeakPhonemes(run, "af_heart").Length);
    }

    /// <summary>Fewer samples than 510 tokens give, roughly: more means nothing was cut off.</summary>
    private static int MaxTokensWorth(KokoroEngine engine)
    {
        var tokens = string.Concat(Enumerable.Repeat("ðə kwˈɪk bɹˈaʊn fˈɑːks, ", 22));
        return engine.SpeakPhonemes(tokens[..KokoroEngine.MaxTokens], "af_heart").Length;
    }

    /// <summary>
    /// The half-precision model on the CPU gives NaN for about one in five of these lengths unless the engine mends it
    /// (see KokoroEngine.RunFinite); the other models give none.
    /// </summary>
    [TestMethod]
    public void NoLengthGivesNaN()
    {
        using var engine = new KokoroEngine(ModelDirectory(), new StubPhonemizer());
        var text = "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ. ɪn nˈaɪntiːn hˈʌndɹɪd twˈɛnti fˈɔːɹ, "
            + "ðə bɹˈɪdʒ wʌz θɹˈiː hˈʌndɹɪd fˈiːt lˈɔŋ. " + HelloPhonemes;
        for (var length = 40; length <= text.Length; length += 5)
        {
            var voice = length % 2 == 0 ? "af_heart" : "bf_emma";
            var audio = engine.SpeakPhonemes(text[..length], voice);
            Assert.IsTrue(audio.All(float.IsFinite), $"{voice}, {length} characters");
            Assert.IsGreaterThan(0.02, Rms(audio), $"{voice}, {length} characters: speech, not silence");
        }
        Console.WriteLine($"{engine.Options.ModelFile}: the model gave NaN {engine.NotFiniteCount} times, mended each time");
    }

    [TestMethod]
    public void OneEngineSpeaksFromSeveralThreads()
    {
        using var engine = new KokoroEngine(ModelDirectory(), new StubPhonemizer());
        var alone = engine.SpeakPhonemes(HelloPhonemes, "af_heart").Length;
        var together = Enumerable.Range(0, 4).AsParallel().WithDegreeOfParallelism(4)
            .Select(i => engine.SpeakPhonemes(HelloPhonemes, i % 2 == 0 ? "af_heart" : "bf_emma").Length).ToList();
        Assert.AreEqual(alone, together[0]);
        Assert.AreEqual(alone, together[2]);
        Assert.IsTrue(together.All(n => n > 0));
    }

    // The sentence voice.

    [TestMethod]
    public void SentenceVoiceDescribesItself()
    {
        using var voice = new KokoroSentenceVoice("nowhere", "bf_emma", new StubPhonemizer());
        Assert.AreEqual("kokoro:bf_emma", voice.Id);
        Assert.AreEqual(24000, voice.SampleRate);
        Assert.IsTrue(voice.KeepsSpoken);
        Assert.IsTrue(((ISentenceVoice)voice).KeepsSpoken, "through the interface too");
        Assert.ThrowsExactly<ArgumentException>(() => new KokoroSentenceVoice("nowhere", "a/b", new StubPhonemizer()));
    }

    [TestMethod]
    public void AcceleratorIsTriedFirst()
    {
        var gpu = new FakeAccelerator([0.5f, -0.5f]);
        // The model directory does not exist: the engine must never be loaded.
        using var voice = new KokoroSentenceVoice("nowhere", "bf_emma", new StubPhonemizer(), accelerator: gpu) { Speed = 1.25f };
        CollectionAssert.AreEqual(new[] { 0.5f, -0.5f }, voice.Speak("Good morning."));
        var call = gpu.Calls.Single();
        Assert.AreEqual(("Good morning.", "bf_emma", Path.Combine("nowhere", "voices", "bf_emma.bin"), "en-gb", 1.25f), call);
        Assert.IsEmpty(voice.Speak(" "));
    }

    [TestMethod]
    public void DeclinedSentencesGoToTheCpu()
    {
        var gpu = new FakeAccelerator(null);
        using var engine = new KokoroEngine(ModelDirectory(), new StubPhonemizer());
        using var voice = new KokoroSentenceVoice(engine, "af_heart", gpu);
        var audio = voice.Speak(HelloPhonemes);
        Assert.HasCount(1, gpu.Calls);
        Assert.IsGreaterThan(0.02, Rms(audio));
        voice.Dispose();
        Assert.IsNotEmpty(engine.SpeakPhonemes(HelloPhonemes, "af_heart"), "a shared engine outlives the voice");
    }

    [TestMethod]
    public void OwnEngineIsLoadedWhenNeededAndFreed()
    {
        var voice = new KokoroSentenceVoice(ModelDirectory(), "af_heart", new StubPhonemizer());
        Assert.IsGreaterThan(0.02, Rms(voice.Speak(HelloPhonemes)));
        voice.Dispose();
        Assert.ThrowsExactly<ObjectDisposedException>(() => voice.Speak(HelloPhonemes));
    }

    // Whisper hears the words.

    [TestMethod]
    public async Task WhisperHearsWhatKokoroSaid()
    {
        var directory = ModelDirectory();
        var phonemizer = Espeak();
        var whisperModel = Environment.GetEnvironmentVariable("SPEECHWARP_LISTEN_MODEL");
        if (string.IsNullOrEmpty(whisperModel))
            Assert.Inconclusive("Set SPEECHWARP_LISTEN_MODEL to a whisper.cpp model to run this test.");
        using var voice = new KokoroSentenceVoice(directory, "af_heart", phonemizer);
        var audio = voice.Speak("The quick brown fox jumps over the lazy dog. In 1924, the bridge was three hundred feet long.");
        using var whisper = new WhisperTranscriber(whisperModel);
        var heard = Plain((await whisper.TranscribeAsync(audio, voice.SampleRate)).Text);
        foreach (var word in new[] { "quick", "brown", "fox", "lazy", "dog", "bridge", "feet", "long" })
            StringAssert.Contains(heard, word, $"Whisper heard: {heard}");
    }
}
