# Changelog

## Unreleased

- **Voices: more engines, one live reader.** Text-to-speech engines implement one small interface,
  `ISentenceVoice` / `SentenceVoice` (with `IPhonemizer` / `Phonemizer` for neural voices).
  - The live reader `VoicedText`, in C# and Swift, reads a text with any engine:
    - it speaks minutes ahead on its own thread, and `Read` never waits;
    - the voice can change between sentences;
    - it reports the character position, and seeks by character or by time;
    - speed-up is optional (`SpeedUp = false` passes the audio through).
  - `VoiceCache` keeps slow voices' audio on disk, in blocks of 40 sentences as AAC.
  - `AppleSentenceVoice` puts Apple's voices behind the interface. `SpokenText` keeps its API and is now a
    wrapper over `VoicedText`.
  - New NuGet packages, all for iOS:
    - `Speechwarp.Voice.Kokoro`: Kokoro-82M on ONNX Runtime, with a catalogue of the model and voice files and
      their hashes, and a benchmark. The engine repairs the fp16 model's occasional NaN output.
    - `Speechwarp.Voice.Kokoro.Gpu`: Kokoro on the iPhone's GPU through MLX. Optional and off by default, on
      screen only, devices on iOS 18 or later.
    - `Speechwarp.Voice.Espeak`: eSpeak NG 1.52.0's voices and its phonemizer for Kokoro.
  - New Swift product: `SpeechwarpVoiceEspeak`, from a framework built locally.
  - New Swift product: `SpeechwarpVoiceKokoro`, Kokoro-82M on ONNX Runtime's CPU (iOS and macOS), the same as
    `Speechwarp.Voice.Kokoro`. ONNX Runtime (Microsoft's Swift package, 1.20.0) comes only with the new package
    trait `Kokoro`, so other users of the package download nothing more. `Package.swift` now needs Swift 6.1 (Xcode
    16.3) for traits and asks for macOS 11; older toolchains read `Package@swift-5.7.swift`, without Kokoro.
  - New Android package `io.github.fredgaffey:speechwarp-voice` (Kotlin, API 21+): the same `SentenceVoice` and
    `Phonemizer`, the live reader `VoicedText`, `VoiceCache` (AAC through MediaCodec) and
    `AndroidSentenceVoice`, Android's own text-to-speech voices.
  - New Android packages for the engines: `io.github.fredgaffey:speechwarp-voice-kokoro` (Kokoro on ONNX
    Runtime's CPU, API 24+; the fp32 model by default, the fastest and NaN-free on an arm64 emulator) and
    `io.github.fredgaffey:speechwarp-voice-espeak` (eSpeak NG 1.52.0 built with the NDK for four ABIs, English
    data in the AAR; **GPL-3.0-or-later**).
  - **The eSpeak packages are GPL-3.0-or-later**, unlike everything else here.
  - See [Voices](docs/voices.md).

- eSpeak NG is a git submodule (`third_party/espeak-ng`, 1.52.0), fetched only when asked for.

- **Word scoring** for the trainer: `speechwarp_score_words` aligns a listener's repeat-back of a sentence
  with the sentence (word-level edit distance on normalised words) and returns the share right with words
  right, missed, wrong and extra. In every binding (`WordScore.Of`, `score_words`, `scoreWords`,
  `ScoreWords`); see docs/api.md.

- **Speech to text with whisper.cpp**, packaged on its own: the NuGet package `Speechwarp.Listen`
  (`WhisperTranscriber`, `WhisperModels`; Windows, Linux, macOS, Android, iOS), the Swift product
  `SpeechwarpListen` (from a framework built locally, see bindings/swift/README.md) and the Python package
  `speechwarp-listen`. The C# and Swift classes implement the engine-independent `ITranscriber` / `Transcriber`
  interface; a session fed in chunks serves a whole book or a microphone. Published by
  `.github/workflows/release-listen.yml`.

- **Speech to text with Apple's recogniser**: `AppleTranscriber` in `SpeechwarpVoice` (Swift, iOS and macOS:
  `SpeechAnalyzer` on iOS 26 and macOS 26, on-device `SFSpeechRecognizer` before) and in `Speechwarp.Voice`
  (C#, iOS: `SFSpeechRecognizer`), through the same interface. `MicrophoneSource` in both feeds the
  microphone to a session of either engine.

- **Docs**: [Speech to text](docs/speech-to-text.md): the interface, both engines, downloading models, the
  microphone, transcribing a whole book, and scoring a sentence said back for the trainer.

- whisper.cpp is a git submodule (`third_party/whisper.cpp`, v1.9.5) that is fetched only when asked for. The
  core packages leave it out even when it is checked out: the crate lists its third-party folders by name, the
  Python licence files are named, and the Flutter and React Native vendor scripts drop it.

## 0.3.7

- **Speech from text on Apple devices**: an optional module, `SpeechwarpVoice` in Swift and the
  `Speechwarp.Voice` package in C# (iOS 16+), reads text aloud with Apple's voices, Eloquence among them, and
  speeds it up with speechwarp. It splits the text into sentences, renders a set number of seconds ahead of
  playback in the background with a cache, reports the character being spoken and seeks by character. The
  core library is unchanged.

## 0.3.6

- **Flutter on the web.** The Flutter package now supports Flutter web, with the same classes, over the library
  compiled to WebAssembly (built by `bindings/flutter/scripts/build_web.sh`, which needs Emscripten, and
  carried inside the pub.dev package). New `Speechwarp.initialize()`: await it once at start-up; on the web it
  loads the WebAssembly, elsewhere it completes at once. Existing native apps need no changes.

## 0.3.5

No changes to the library. The first release that every registry publishes from GitHub with no stored
token (React Native on npm, crates.io and pub.dev switch to trusted publishing).

## 0.3.4

The first release from GitHub to every registry; 0.3.1 to 0.3.3 were tags only and were never published.

- Packages for crates.io (Rust), npm (React Native), NuGet (.NET), Maven Central (Android and desktop Java)
  and pub.dev (Flutter), each published by a version tag.
- .NET on Windows: the native library is now libspeechwarp.dll. As speechwarp.dll it had the same file name as
  the managed Speechwarp.dll, so wherever both landed in one folder every call failed.
- The project moved to github.com/fredgaffey/speechwarp. The Go module path is now
  github.com/fredgaffey/speechwarp, and the Java and Kotlin package is io.github.fredgaffey.speechwarp.
- The Android library on Maven Central is io.github.fredgaffey:speechwarp-android, separate from the desktop
  Java io.github.fredgaffey:speechwarp.

## 0.3.0 (unreleased)

Things any player can use to train for very high speeds. All off unless asked for; with them off, the output
is the same as 0.2.0's.

- **Heard pause**: the pause cap follows the speed, set as the length of pause the listener should hear (the
  cap is that times the speed, 0.03 to 0.4 s of input), from a chosen speed up. A fixed cap is heard as
  roughly the cap over the speed, so pauses all but vanished at 7.5x.
- **Floor blend**: the speed floor rises linearly from 0 at one speed to a set fraction at another, so a speed
  ramp never changes the sound in a jump. Both rules are reapplied whenever the speed changes, and each
  replaces its fixed option.
- **Syllable counter on its own** (`speechwarp_syllables_*`), the same algorithm and results as the stream's,
  with a choice of window, for players that use another speed-up.
- **Listener trainer** (`speechwarp_trainer_*`): pure logic in syllables a second heard. Threshold tests by
  the psi method with a 95% interval; four session plans (steady, ramp, interval, tracking); and Thompson
  sampling over plans on threshold gain a hour, allowing for gains that slow with practice and costing lost
  retention. Deterministic for a seed.
- **Blind trials** (`speechwarp_trials_*`): which setting and values to compare next at a speed, results by
  speed band, and a winner named only when a Bayes factor says so.
- All of it in every binding. The command-line tool gains `--heard-pause` and `--floor-blend`.
- Research notes: how comprehension is measured, the test protocol, and the trainer's design.

## 0.2.0 (unreleased)

Options for listening at 5x to 8x, all off by default; with them off, the output is the same as 0.1.0's.
See [How it works](docs/how-it-works.md#options-for-very-high-speeds).

- **Pause cap**: shorten every pause to at most a set length before speeding up.
- **Keep overall speed** (on by default while the pause cap or rhythm is on): time saved in pauses is spent
  playing the words slower, and time spent in rhythm gaps is made up, so the overall speed stays as set.
- **Speed floor**: no part of the speech slower than a set fraction of the speed.
- **Rhythm**: short silences put into the output at a regular rate, at the quietest point nearby.
- **Syllable rate**: an estimate of the syllables a second being spoken, ported from the player's C#.
- All of them in every binding. The command-line tool gains `--pause-cap`, `--floor`, `--rhythm-gap`,
  `--rhythm-rate` and `--no-keep-speed`, and `--verbose` reports syllables a second; the blind A/B example can
  compare any two settings.

## 0.1.0 (unreleased)

The first version.

- C library: streaming nonlinear (Speedy) and even (Sonic) speed-up behind `speechwarp.h`, with the average
  speed held at the one requested, and `speechwarp_position` for mapping output back to input.
- `speechwarp` command-line tool for WAV files.
- Bindings for C#/.NET, Python, Swift, Kotlin (Android), JavaScript (WebAssembly), Dart (Flutter), React
  Native, Rust, Go and desktop Java.
