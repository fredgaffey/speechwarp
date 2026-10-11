# speechwarp-voice-espeak

> **Licence: GPL-3.0-or-later.** This library contains eSpeak NG, which is licensed under the GNU General Public
> License, version 3 or later, and so this library is too, unlike the other speechwarp libraries (Apache-2.0).
> **Using this library makes your app subject to the GPL-3.0:** if you distribute the app, you must distribute it
> under the GPL-3.0 and offer its complete source code. If that does not suit, do not use this library; Kokoro
> (speechwarp-voice-kokoro) takes any `Phonemizer`, so another phonemizer can take eSpeak's place there.

[eSpeak NG](https://github.com/espeak-ng/espeak-ng) 1.52.0 for Android 5.0 (API 21) and later, linked into the
app:

- `EspeakSentenceVoice`: speech in eSpeak's own formant voices, as a `SentenceVoice` for speechwarp-voice's live
  reader and cache. It is quick enough to speak as it is heard.
- `EspeakPhonemizer`: text to phonemes (IPA), as a `Phonemizer` for Kokoro (speechwarp-voice-kokoro).
- `Espeak`: the same directly, with the voices and variants in its data.

The AAR carries eSpeak for arm64-v8a, armeabi-v7a, x86_64 and x86 (aligned for 16 KB pages, only its JNI functions
exported, so it cannot clash with another copy of eSpeak in the app) and eSpeak's English data in its assets (about
1.2 MB: American, New York, British, Received Pronunciation, Scottish, Lancaster, West Midlands, Caribbean and
Shavian). eSpeak reads its data from files, so `Espeak.initialize(context)` copies it to
`files/speechwarp-espeak/espeak-ng-data` the first time, and again only when an update of the app changes it.
Nothing is downloaded.

```kotlin
import io.github.fredgaffey.speechwarp.voice.espeak.Espeak
import io.github.fredgaffey.speechwarp.voice.espeak.EspeakPhonemizer
import io.github.fredgaffey.speechwarp.voice.espeak.EspeakSentenceVoice

// The constructors that take a context put the data in place first (the first time copies 1.2 MB: not on the
// main thread). 175 words a minute and pitch 50 unless you say otherwise.
val voice = EspeakSentenceVoice(context, "en-gb")      // voice.id is "espeak:en-gb"
val samples = voice.speak("The quick brown fox jumps over the lazy dog.")   // mono, voice.sampleRate (22,050)

// Phonemes for Kokoro.
val kokoro = KokoroSentenceVoice(directory, "af_heart", EspeakPhonemizer(context))

// Directly, once Espeak.initialize(context) has been called.
val ipa = Espeak.phonemes("The quick brown fox", "en-us")   // "ðə kwˈɪk bɹˈaʊn fˈɑːks"
val fast = Espeak.speak("Faster.", "en-us+klatt", wordsPerMinute = 300, pitch = 40)
for (v in Espeak.voices) println("${v.language}: ${v.name}")   // EspeakVoice: name, language, identifier, gender
val variants = Espeak.variants                                // "klatt", "f3", "m1", ... (after a '+')
```

- A voice away from the default rate or pitch has them in its id: `EspeakSentenceVoice(context, "en-gb", 220)` is
  "espeak:en-gb/220/50".
- "en-gb" names no file in eSpeak's data (British English is `gmw/en`), so a language eSpeak cannot find by name
  is looked up as its own command does, keeping any variant ("en-gb+klatt").
- eSpeak keeps its state in globals, so every call takes one lock and calls from several threads take turns.
- It is started with the `espeak_ng_*` calls on purpose: the older `espeak_Initialize` ends the whole process when
  it cannot find its data, where these throw `IllegalStateException`. A voice eSpeak lacks throws
  `IllegalArgumentException`.
- To use data of your own (more languages, say), set `Espeak.dataPath` to its `espeak-ng-data` folder before the
  first call, and use the constructors without a context.

## Getting it

From Maven Central, once a release has been published:

```kotlin
implementation("io.github.fredgaffey:speechwarp-voice-espeak:<version>")
```

## Building it here

The repository holds neither the built library nor the data. The Gradle build makes both from the
`third_party/espeak-ng` submodule (pinned to the 1.52.0 tag, and not fetched by default):

```sh
git submodule update --init --checkout third_party/espeak-ng
cd bindings/android
./gradlew :speechwarp-voice-espeak:testReleaseUnitTest   # on this computer's JVM, against a host build
./gradlew :speechwarp-voice-espeak:assembleRelease
```

`src/main/cpp/CMakeLists.txt` compiles the library directly (as
`bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh` does for Apple systems), without audio
output, MBROLA, Sonic or the speech player, with Klatt, and with a 1,024-byte data path. Built for this computer,
the same project gives upstream's `espeak-ng` command, which `compile-espeak-data.sh` uses to compile the data as
upstream's Makefile does. It needs `cmake` and a C compiler on the path, on macOS or Linux. More languages:
`ESPEAK_DICTIONARIES="en de fr"` in the environment of the build.

The instrumented tests (`src/androidTest`) check the data, the IPA and the audio on a device or emulator, and speak
Kokoro with eSpeak's phonemes when a Kokoro model has been pushed to `/data/local/tmp/kokoro-model` (or the folder
given as the instrumentation argument `kokoroModelDir`).

Not an official eSpeak NG product. eSpeak NG's licence is in `COPYING`; inside the AAR (in `classes.jar`),
`META-INF/licenses/speechwarp-voice-espeak/` holds it with the notices of the parts of eSpeak NG under other
licences (Apache-2.0, BSD-2-Clause, the Unicode data licence) and speechwarp's own.
