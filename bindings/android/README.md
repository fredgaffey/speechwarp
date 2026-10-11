# speechwarp for Android

Nonlinear speed-up for speech: listen faster and still follow it. This is the Kotlin binding of
[speechwarp](https://github.com/fredgaffey/speechwarp), which packages Google's Speedy algorithm and the
Sonic library. It is not an official Google product.

```kotlin
import io.github.fredgaffey.speechwarp.SpeechwarpStream

SpeechwarpStream(sampleRate = 44100, channels = 2).use { stream ->
    stream.speed = 3f

    stream.write(input)                       // interleaved ShortArray or FloatArray
    val frames = stream.read(buffer)          // frames, not samples
    audioTrack.write(buffer, 0, frames * stream.channels)

    stream.flush()                            // at the end of the input; then read until it returns 0
}
```

It works from Java too: the optional arguments have overloads.

- `speed` is the speed you get, within a few percent. `nonlinear = 0f` switches to plain, even speed-up and
  can be changed during playback.
- `position` is the input frame being heard. The speed varies from moment to moment, so a player cannot work
  that out by multiplying. Call `reset()` after a seek.
- A stream is not thread safe. `close()` it when done.

The library is an AAR for Android 5.0 (API 21) and later, with native code for arm64-v8a, armeabi-v7a, x86_64
and x86, aligned for 16 KB pages.

## Very high speeds

For 5x and beyond, a few options take some of the speed from pauses rather than words and give the
listener a rhythm to follow. All are off by default. What each does, and how they did in a first test, is in
[How it works](../../docs/how-it-works.md#options-for-very-high-speeds).

```kotlin
stream.speed = 6.5f
stream.pauseCap = 0.06f   // shorten every pause to at most 60 ms
stream.speedFloor = 0.5f  // no part of the speech slower than half the speed
stream.rhythmGap = 0.04f  // a 40 ms silence...
stream.rhythmRate = 6f    // ...six times a second
// keepSpeed (true by default) holds the overall speed at 6.5x despite all of that.
```

`syllableRate` is an estimate of the syllables a second in the input, over the last minute; multiply it by the
speed for the rate heard. It is `null` until 10 s have been written.

## Text read aloud: speechwarp-voice

A second package, `io.github.fredgaffey:speechwarp-voice` (module `speechwarp-voice`, package
`io.github.fredgaffey.speechwarp.voice`), reads text aloud with any text-to-speech engine and speeds it up:

- `VoicedText`, the live reader: speaks sentences ahead on its own thread, `read` never waits, the voice can change
  between sentences, and it reports and seeks by character or by time.
- `AndroidSentenceVoice`: Android's own text-to-speech voices. Never call `speak` on the main thread.
- `VoiceCache`: slow voices' sentences kept on disk as AAC.
- `SentenceVoice` and `Phonemizer`: the interfaces other engines implement.

See [Voices](../../docs/voices.md#on-android).

```kotlin
// On a background thread: the system's text-to-speech starts asynchronously and reports to the main thread.
val voice = AndroidSentenceVoice.open(context, "en-us-x-iol-local")
val book = VoicedText(text, voice).apply { speed = 3f }
val frames = book.read(buffer)            // on the audio thread: mono, book.sampleRate
```

## Voice engines: Kokoro and eSpeak NG

Two more libraries plug engines into `speechwarp-voice`, as the C# packages `Speechwarp.Voice.Kokoro` and
`Speechwarp.Voice.Espeak` do on iOS. See [Voices](../../docs/voices.md#kokoro-and-espeak-on-android).

- `io.github.fredgaffey:speechwarp-voice-kokoro` (module `speechwarp-voice-kokoro`, Apache-2.0, API 24+):
  Kokoro-82M, a neural voice, on ONNX Runtime's CPU. `KokoroSentenceVoice` (id "kokoro:af_heart", 24 kHz,
  `keepsSpoken`), `KokoroEngine`, `KokoroModels` (every file to download, with its size and SHA-256; the library
  never uses the network) and `KokoroBenchmark`. The default model on Android is `model.onnx` (fp32, 326 MB): on an
  arm64 emulator it was the fastest and never gave NaN. It takes any `Phonemizer`.
- `io.github.fredgaffey:speechwarp-voice-espeak` (module `speechwarp-voice-espeak`, API 21+):
  **GPL-3.0-or-later**, unlike everything else here. **An app that uses it must be distributed under the GPL-3.0,
  with its complete source.** eSpeak NG 1.52.0: `EspeakSentenceVoice` (id "espeak:en-gb"), `EspeakPhonemizer` for
  Kokoro, and `Espeak`. Native code for the same four ABIs, and English data copied from the AAR's assets to the
  app's files folder on first use. Read [its README](speechwarp-voice-espeak/README.md) first.

```kotlin
// Off the main thread. The model directory holds what KokoroModels.missingFiles(directory, "af_heart") listed.
val kokoro = KokoroSentenceVoice(directory, "af_heart", EspeakPhonemizer(context))
val samples = kokoro.speak("The sun had not yet risen over the hills.")   // mono, 24 kHz

val espeak = EspeakSentenceVoice(context, "en-gb")     // 22,050 Hz, far faster than listening
```

## Getting it

From Maven Central, once a release has been published:

```kotlin
implementation("io.github.fredgaffey:speechwarp-android:0.3.7")
```

`speechwarp-voice` is published, at the same version, from the first release that has it (see CHANGELOG.md), and
brings `speechwarp-android` with it, as do `speechwarp-voice-kokoro` and `speechwarp-voice-espeak` (GPL-3.0-or-later).

## Building it here

Needs the Android SDK with NDK 27.1.12297006 and CMake 3.22.1, a JDK, and `cmake` on the path for the tests.

```sh
./gradlew :speechwarp:testReleaseUnitTest   # runs on this computer's JVM, against a native build for it
./gradlew :speechwarp:assembleRelease       # speechwarp/build/outputs/aar/speechwarp-release.aar
./gradlew :speechwarp:publishToMavenLocal   # to use it from another project on this computer

./gradlew :speechwarp-voice:testReleaseUnitTest         # the reader and cache with a fake voice, on this JVM
./gradlew :speechwarp-voice:connectedDebugAndroidTest   # on an emulator or device: text-to-speech, AAC, the reader

git -C ../.. submodule update --init --checkout third_party/espeak-ng   # eSpeak NG, for speechwarp-voice-espeak
./gradlew :speechwarp-voice-kokoro:testReleaseUnitTest  # Kokoro's logic with a stand-in for the model
./gradlew :speechwarp-voice-espeak:testReleaseUnitTest  # eSpeak on this JVM, against a host build and the data
./gradlew :speechwarp-voice-kokoro:assembleRelease :speechwarp-voice-espeak:assembleRelease
```

The Kokoro tests that need a real model are instrumented ones. Push a model directory (model.onnx, tokenizer.json,
voices/af_heart.bin and voices/bf_emma.bin) to `/data/local/tmp/kokoro-model`, or name another with the
instrumentation argument `kokoroModelDir`; without one they are skipped. `-e kokoroCompare true` times each model
(the table in docs/voices.md):

```sh
adb push kokoro-model /data/local/tmp/
./gradlew :speechwarp-voice-kokoro:connectedDebugAndroidTest :speechwarp-voice-espeak:connectedDebugAndroidTest
```

The unit tests do not run on a phone. `speechwarp-voice`'s instrumented tests have run on an Android 16 emulator
(arm64, which also loads the core's native library), and so have the Kokoro and eSpeak modules' (with a real
Kokoro model); nothing has been run on a real device yet.
