# Speechwarp.Voice.Kokoro

[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), a small neural text-to-speech model, run on the device
with ONNX Runtime, as an `ISentenceVoice` for Speechwarp.Voice's live reader and voice cache. For iOS 16 and later.
Apache-2.0, as is the model. Not an official Kokoro, hexgrad or Microsoft product.

Kokoro reads phonemes, not text. This package does not make them: give it an `IPhonemizer`. Speechwarp.Voice.Espeak
supplies `EspeakPhonemizer` (eSpeak NG, as kokoro.js and kokoro-onnx use), which is GPL-3.0-or-later; keeping it
in a separate package keeps this one Apache-2.0. Any other phonemizer that produces eSpeak-style IPA works.

```csharp
using Speechwarp.Voice;
using Speechwarp.Voice.Espeak;
using Speechwarp.Voice.Kokoro;

// A model directory the app has downloaded into (see below).
var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Personal), "Kokoro");

// One voice, for the live reader or the voice cache: id "kokoro:af_heart", 24 kHz, KeepsSpoken.
using var voice = new KokoroSentenceVoice(directory, "af_heart", new EspeakPhonemizer());
float[] samples = voice.Speak("The sun had not yet risen over the hills.");

// Several voices sharing one engine (the model is the large part, about its file size in memory).
using var engine = new KokoroEngine(directory, new EspeakPhonemizer());
using var heart = new KokoroSentenceVoice(engine, "af_heart");
using var emma = new KokoroSentenceVoice(engine, "bf_emma");

// The engine directly: any amount of text, a speed, the phonemes it used.
float[] audio = engine.Speak("Two sentences. Or more.", "bm_george", speed: 1.1f);
string ipa = engine.Phonemize("Hello world.", "en-gb");
```

Speechwarp.Voice.Kokoro.Gpu adds Kokoro on the iPhone's GPU (MLX) as an `IKokoroAccelerator`, passed to
`KokoroSentenceVoice`; it takes each sentence it can and leaves the rest to ONNX Runtime.

## The model directory

```
model_fp16.onnx        or another of KokoroModels.Models (KokoroOptions.ModelFile chooses)
tokenizer.json
voices/af_heart.bin    one per voice
```

`KokoroModels` lists every file with its download URL, size and SHA-256, from
[onnx-community/Kokoro-82M-v1.0-ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) at a fixed
revision. The package never uses the network: the app downloads what `KokoroModels.MissingFiles(directory, voice)`
returns, checks each file's hash, and `KokoroModels.IsInstalled(directory, voice)` then says yes. The default model
(fp16) is 163 MB, each voice 0.5 MB. 54 voices in nine languages are listed; only the English ones (names starting
a, American, and b, British) have been tried.

## Options

`KokoroOptions`: `ModelFile`, `Threads` (0 = one a core) and `Provider` (`KokoroProvider.Cpu`, or
`KokoroProvider.CoreML` for Apple's Neural Engine and GPU where the model allows). Core ML cannot take most of
Kokoro's graph (its lengths are not fixed), so on a Mac it was slower than the CPU and logs a page of warnings.

## Which model

The default, model_fp16 (163 MB), is the one existing apps have. On ONNX Runtime's CPU it gives NaN for the whole of
some inputs (about one in five of the lengths tried on a Mac), depending on the exact phonemes. The engine checks
every answer and runs such pieces again (with a space added, then split in two), so callers never get NaN, but each
mended piece costs one to three more runs. The full-precision model (model.onnx, 326 MB) gave no NaN and was the
fastest on the Mac's CPU; q8f16 (86 MB) gave no NaN and was the slowest. Measured on an M-series Mac only.

## Threads

`KokoroEngine.Speak` may be called from several threads at once if the phonemizer allows it. `KokoroSentenceVoice` is
called from one thread at a time, as every `ISentenceVoice` is.

## Speed

`KokoroBenchmark.Run` measures it on the device (the real-time factor is seconds of work per second of audio). On an
M-series Mac's CPU, 20 s runs gave real-time factors of 0.32 for model.onnx, 0.37 for model_fp16 and 0.59 for
model_q8f16 (3.2x, 2.7x and 1.7x faster than listening); a phone is slower, which is why `KeepsSpoken` is true.
The desktop sample `Speechwarp.Voice.Kokoro.Bench` runs it with the `espeak-ng` command:

```sh
dotnet run -c Release --project bindings/dotnet/Speechwarp.Voice.Kokoro.Bench -- MODEL_DIR [TEXT_FILE] --seconds 30
```
