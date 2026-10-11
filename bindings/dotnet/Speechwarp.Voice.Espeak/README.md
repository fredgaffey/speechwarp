# Speechwarp.Voice.Espeak

> **Licence: GPL-3.0-or-later.** This package contains eSpeak NG, which is licensed under the GNU General Public
> License, version 3 or later, and so this package is too, unlike the other speechwarp packages (Apache-2.0).
> **Using this package makes your app subject to the GPL-3.0:** if you distribute the app, you must distribute it
> under the GPL-3.0 and offer its complete source code. If that does not suit, do not use this package; Kokoro
> (Speechwarp.Voice.Kokoro) takes any `IPhonemizer`, so another phonemizer can take eSpeak's place there.

[eSpeak NG](https://github.com/espeak-ng/espeak-ng) 1.52.0 for iOS 16 and later, linked into the app:

- `EspeakSentenceVoice`: speech in eSpeak's own formant voices, as an `ISentenceVoice` for the live reader and
  the cache of Speechwarp.Voice. It is quick enough to speak as it is heard.
- `EspeakPhonemizer`: text to phonemes (IPA), as an `IPhonemizer` for Kokoro (Speechwarp.Voice.Kokoro).
- `Espeak`: the same directly, with the voices and variants in its data.

The package carries eSpeak's English data (about 1.2 MB: American, New York, British, Received Pronunciation,
Scottish, Lancaster, West Midlands, Caribbean and Shavian), which it puts in the app bundle as `espeak-ng-data/`,
where `Espeak.DataPath` finds it. eSpeak is a static library for devices and the simulator; nothing is
downloaded.

```csharp
using Speechwarp.Voice.Espeak;

// A sentence voice: 175 words a minute and pitch 50 unless you say otherwise.
using var voice = new EspeakSentenceVoice("en-gb");     // voice.Id is "espeak:en-gb"
float[] samples = voice.Speak("The quick brown fox jumps over the lazy dog.");   // mono, voice.SampleRate (22,050)

// Phonemes for Kokoro.
var kokoro = new KokoroSentenceVoice(folder, "af_heart", new EspeakPhonemizer());

// Directly.
var ipa = Espeak.Phonemes("The quick brown fox", "en-us");   // "ðə kwˈɪk bɹˈaʊn fˈɑːks"
var fast = Espeak.Speak("Faster.", "en-us+klatt", wordsPerMinute: 300, pitch: 40);
foreach (var v in Espeak.Voices)                              // EspeakVoice: Name, Language, Identifier, Gender
    Console.WriteLine($"{v.Language}: {v.Name}");
var variants = Espeak.Variants;                               // "klatt", "f3", "m1", ... (after a '+')
```

eSpeak keeps its state in globals, so every call takes one lock and calls from several threads take turns. It
starts on first use; to keep its data elsewhere, set `Espeak.DataPath` (the folder `espeak-ng-data`) before that.
It is started with the `espeak_ng_*` calls on purpose: the older `espeak_Initialize` ends the whole app when it
cannot find its data, where these throw `InvalidOperationException`. A voice eSpeak lacks throws
`ArgumentException`.

## Building the native library

The repository does not hold the built library or data. `native-build/build-espeak.sh` builds both from the
`third_party/espeak-ng` submodule (pinned to the 1.52.0 tag, and not fetched by default):

    git submodule update --init --checkout third_party/espeak-ng
    bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh          # then dotnet pack

It compiles the library directly with Xcode's compilers (eSpeak's CMake install rules fail for iOS) into
`native/ios/espeak-ng.xcframework`, without audio output, MBROLA, Sonic or the speech player, and with a
1,024-byte data path, because eSpeak's default of 160 bytes is shorter than an app's path in the simulator. It
then builds upstream's `espeak-ng` command for the Mac and compiles the data with it, as upstream's Makefile does,
into `native/espeak-ng-data`. More languages: `ESPEAK_DICTIONARIES="en de fr" build-espeak.sh`. With `swift` or
`all` it also builds the framework (with a macOS slice) and data for the Swift package's SpeechwarpVoiceEspeak.

Not an official eSpeak NG product. eSpeak NG's licence is in `COPYING`; the notices of the parts of it under other
licences (Apache-2.0, BSD-2-Clause, the Unicode data licence) are in `licenses/espeak-ng/`.
