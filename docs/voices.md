# Voices: speech from text

speechwarp can read text aloud on the device, sped up like any recording, through one interface with several
engines behind it. A player reads a book sentence by sentence, can change the voice between sentences, keeps slow
voices' audio on disk, and knows which character is being spoken.

| Engine | C# package | Swift | Licence | Speed | Notes |
|---|---|---|---|---|---|
| **Apple's voices** (Eloquence and the system's others) | `Speechwarp.Voice` | `SpeechwarpVoice` | Apache-2.0 | far faster than listening | built in, nothing to download |
| **Kokoro-82M** on ONNX Runtime (CPU) | `Speechwarp.Voice.Kokoro` | - | Apache-2.0 (and the model) | about 2x real time in the iOS simulator on a Mac; not yet measured on a phone | neural; the app downloads a model (163 MB) |
| **Kokoro-82M** on the GPU (MLX) | `Speechwarp.Voice.Kokoro.Gpu` | - | Apache-2.0 | not yet shown to work on a phone | optional, off by default, devices only |
| **eSpeak NG** | `Speechwarp.Voice.Espeak` | `SpeechwarpVoiceEspeak` | **GPL-3.0-or-later** | far faster than listening | formant voices; also the phonemizer for Kokoro |

All the C# packages are for iOS 16 and later (`net10.0-ios`). They are published from the release after 0.3.7;
until then build them from this repository.

> **eSpeak NG is GPL-3.0-or-later.** So is `Speechwarp.Voice.Espeak` (and the Swift product
> `SpeechwarpVoiceEspeak`), unlike every other speechwarp package. An app that uses it must be distributed under the
> GPL-3.0, with its complete source. Kokoro needs a phonemizer but not this one: it takes any `IPhonemizer`, so an
> app that cannot be GPL can supply its own.

## The interface

Two interfaces in `Speechwarp.Voice` (Swift: `SpeechwarpVoice`) are all an engine implements:

| C# | Swift | What it is |
|---|---|---|
| `ISentenceVoice` | `SentenceVoice` | speaks one sentence: `Id` (stable, such as "apple:com.apple.eloquence.en-US.Reed", "kokoro:af_heart", "espeak:en-gb"), `SampleRate`, `Speak(sentence)` returning mono floats, `KeepsSpoken` (true for an engine slow enough that its audio is worth keeping on disk) |
| `IPhonemizer` | `Phonemizer` | text to IPA for a neural voice: `Phonemize(text, language)` |

Engines: `AppleSentenceVoice`, `KokoroSentenceVoice`, `EspeakSentenceVoice`. Phonemizer: `EspeakPhonemizer`.

## The live reader

`VoicedText` reads a whole text with any `ISentenceVoice`:

- It splits the text into sentences and speaks them on a thread of its own, ahead of what is being played:
  `Lookahead` seconds (30) for a quick voice, `KeptLookahead` (120) for one that `KeepsSpoken`.
- `Read(buffer)` is for the audio thread and never waits. When the next sentence is not ready it returns what
  there is and `IsWaiting` says so.
- The audio goes through a speechwarp stream (`Speed`, `Configure`), or passes through unchanged with
  `SpeedUp = false`, for a player with its own speed-up.
- Voices at another sample rate are resampled to the reader's own.
- `CharacterPosition` and `SentenceIndex` say what is being heard. `Seek(character)` and `Seek(TimeSpan)` jump.
  `TimeAt(frame)` and `Duration` place it all on a timeline of the text's characters at `SecondsPerCharacter`
  each, which is the same whatever the voice and speed.
- The voice can change between sentences. `SetVoice(voice)` takes effect at once. With a factory,
  `SetVoice("kokoro:af_heart")` makes the voice on the reader's thread (loading a model takes a while). Either
  way, the change applies from the next sentence not yet started, and what was spoken ahead in the old voice is
  dropped.
- The reader owns its voices and disposes each one on its own thread, never while it is mid-sentence.

```csharp
using Speechwarp.Voice;
using Speechwarp.Voice.Espeak;
using Speechwarp.Voice.Kokoro;

// A factory: the reader makes voices by id, on its own thread.
ISentenceVoice Make(string id) => id switch
{
    _ when id.StartsWith("apple:") => new AppleSentenceVoice(id),
    _ when id.StartsWith("espeak:") => new EspeakSentenceVoice(id["espeak:".Length..]),
    _ when id.StartsWith("kokoro:") => new KokoroSentenceVoice(modelDirectory, id["kokoro:".Length..], new EspeakPhonemizer()),
    _ => throw new ArgumentException(id),
};

using var book = new VoicedText(text, "apple:com.apple.eloquence.en-US.Reed", Make,
    new VoicedTextOptions { CacheDirectory = VoiceCache.DefaultDirectory }) { Speed = 2 };
int frames = book.Read(buffer);              // on the audio thread; mono at book.SampleRate
int at = book.CharacterPosition;             // for highlighting
book.SetVoice("kokoro:af_heart");            // from the next sentence not yet started
```

The Swift reader is the same (`VoicedText`, `VoicedText.Options`, `setVoice(id:)`, `read(maxFrames:)`,
`seek(toCharacter:)`), with the Apple and eSpeak engines; Kokoro is C# only.

`SpokenText`, the Apple-only reader from 0.3.7, is unchanged and now a thin wrapper over `VoicedText`.

## The voice cache

A slow voice (Kokoro on a phone speaks little faster than it is heard) is worth speaking once. With
`VoicedTextOptions.CacheDirectory` set, the reader keeps the audio of every voice that `KeepsSpoken` in a
`VoiceCache` and reads it from there next time:

- The audio is kept in blocks of 40 sentences, each block one AAC file (32 kbit/s) with each sentence's length
  beside it as JSON.
- The path is `directory/<the text's key>/<voice id>/00000.m4a`. The text's key is the first 16 hex digits of
  the text's SHA-256.
- `VoiceCache.DefaultDirectory` is in Library/Caches, which iOS may clear when space is short.
- `SpeakAheadToDisk` is a `Func<bool>`, asked when the lookahead is full. While it returns true (say, while the
  phone is charging), the reader carries on speaking whole blocks to disk.
- `VoiceCache` can also be used directly, to voice a book overnight: `Has`, `Load`, `Save`, `Remove`, `Clear`.

A block is written on the reader's thread once its last sentence is spoken, which can be just after reading
finishes. `Dispose` does not wait for that write; the write still finishes in the background.

## Kokoro

`Speechwarp.Voice.Kokoro` runs [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) on ONNX Runtime 1.23.2:

- Classes: `KokoroEngine` for the model, and `KokoroSentenceVoice` (id "kokoro:NAME", 24 kHz, `KeepsSpoken`)
  for the reader.
- Several voices can share one engine; the model is the large part.
- It needs an `IPhonemizer`, such as eSpeak's.

### Downloading the model

The package never uses the network. `KokoroModels` lists every file with its size, SHA-256 and download URL. The
files come from [onnx-community/Kokoro-82M-v1.0-ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX)
at a fixed revision, so the hashes always match. The app downloads what
`KokoroModels.MissingFiles(directory, voice)` returns and checks each hash. After that,
`KokoroModels.IsInstalled(directory, voice)` is true.

```
model_fp16.onnx       the default (163 MB); KokoroOptions.ModelFile picks another of KokoroModels.Models
tokenizer.json
voices/af_heart.bin   one per voice (0.5 MB each); KokoroModels.Voices lists 54
```

On ONNX Runtime's CPU the fp16 model gives all-NaN audio for some inputs: 19 of 90 lengths tried on a Mac. The
engine checks every result and speaks such a piece again, with a space added, then split in two. Anything that
still fails becomes silence, so callers never see NaN. The fp32 model (`model.onnx`, 326 MB) gave no NaN and ran
a little faster on a Mac's CPU. It has not yet been checked whether a phone behaves the same way.

`KokoroBenchmark.Run` measures how fast Kokoro speaks on the device. The desktop sample
`bindings/dotnet/Speechwarp.Voice.Kokoro.Bench` runs it on a Mac.

### On the GPU

`Speechwarp.Voice.Kokoro.Gpu` runs Kokoro on the iPhone's GPU through MLX
([mlalma/kokoro-ios](https://github.com/mlalma/kokoro-ios)). It plugs into the CPU package as an
`IKokoroAccelerator`:

```csharp
KokoroGpu.WatchAppState();                                   // once, at launch, on the main thread
var voice = new KokoroSentenceVoice(directory, "af_heart", new EspeakPhonemizer(),
    accelerator: new KokoroGpuAccelerator(directory));
```

Caveats:

- **Off by default.** It is used only when the model directory also holds `kokoro-v1_0.safetensors` (327 MB,
  `KokoroGpu.Model`) and a file named `use-gpu`.
- **Foreground only.** iOS refuses GPU work from an app in the background, and MLX then ends the process. So no
  sentence starts on the GPU while the app is not active. When the app is about to leave the screen, its main
  thread waits (up to 8 s) for the sentence under way. Without `WatchAppState()` the GPU is never used.
- **Devices on iOS 18 or later only.**
  - Simulator builds leave the framework out. There `KokoroGpu.IsIncluded` is false and the CPU speaks.
  - The framework is embedded but not linked, and loaded at run time, so an app whose minimum is iOS 16 still
    starts on iOS 16 and 17.
- **English voices only** (a* American, b* British). Any other voice goes to the CPU.
- **Not yet shown to work on a phone.** In the one test so far it started and produced no audio. Until that is
  understood, every call has a time limit (`KokoroGpu.Timeout`, 90 s). When it runs out, or after three failures
  in a row, the CPU speaks for the rest of the run.
  - Memory is the main suspect: on a Mac a long sentence peaked at about 2.3 GB.
  - `KokoroGpu.Log` reports timings for diagnosis.
- It adds about 42 MB to a device build. Set the MSBuild property `SpeechwarpKokoroGpu` to `false` to leave it
  out.

## eSpeak NG

`Speechwarp.Voice.Espeak` links [eSpeak NG](https://github.com/espeak-ng/espeak-ng) 1.52.0 into the app:

- `EspeakSentenceVoice(language, wordsPerMinute = 175, pitch = 50)`: id "espeak:en-gb", or
  "espeak:en-gb/220/50" away from the default rate and pitch.
- `EspeakPhonemizer`: IPA for Kokoro.
- `Espeak`: the same calls directly, plus `Voices` and `Variants`.

It carries eSpeak's English data (about 1.2 MB), which goes into the app bundle as `espeak-ng-data/`. Every call
takes turns on one eSpeak.

Read the licence note at the top of this page before using it.

## Building the native parts

Nothing built is committed. CI builds all of it for the packages.

- **eSpeak:** run `git submodule update --init --checkout third_party/espeak-ng`, then
  `bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh [dotnet|swift|all]`. `swift` builds the
  framework and data that make the `SpeechwarpVoiceEspeak` product appear in `Package.swift`; run
  `swift package purge-cache` afterwards.
- **Kokoro on the GPU:** `bindings/swift/KokoroGPU/build-frameworks.sh`. It needs Xcode's Metal toolchain: if
  `xcrun -f metal` finds nothing, run `xcodebuild -downloadComponent MetalToolchain`. It also needs the network,
  because it fetches kokoro-ios, MisakiSwift and MLX at pinned versions.

Both packages refuse to pack without their native parts.
