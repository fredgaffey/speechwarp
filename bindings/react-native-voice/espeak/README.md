# react-native-speechwarp-voice-espeak

[eSpeak NG](https://github.com/espeak-ng/espeak-ng) 1.52.0 for
[react-native-speechwarp-voice](../README.md): its formant voices, and its phonemizer, which Kokoro
([react-native-speechwarp-voice-kokoro](../kokoro/README.md)) needs.

> **GPL-3.0-or-later**, as eSpeak NG is, unlike the other speechwarp packages. An app that includes this package must
> be distributed under the GPL-3.0 too, with its complete source.

```sh
npm install react-native-speechwarp-voice react-native-speechwarp-voice-espeak
cd ios && pod install
```

Nothing needs calling: once the app is rebuilt, `listVoices()` lists eSpeak's voices (English in nine accents:
"espeak:en-us", "espeak:en-gb", "espeak:en-gb-x-rp" ...), and `createReader` and `setVoice` take them.

```ts
import { createReader } from 'react-native-speechwarp-voice';
import { espeakVoiceId } from 'react-native-speechwarp-voice-espeak';

const reader = await createReader(text, espeakVoiceId('en-gb', 220));   // "espeak:en-gb/220/50"
```

- `espeakVoiceId(language, wordsPerMinute = 175, pitch = 50)`: a voice's id; the language may name a variant
  ("en-us+klatt", see `espeakVariants()`).
- `espeakAvailable()`, `espeakVersion()`, `espeakVariants()`, `espeakPhonemize(text, language)`.

It is a thin layer over speechwarp's eSpeak libraries: on Android `io.github.fredgaffey:speechwarp-voice-espeak` from
Maven Central (eSpeak built with the NDK, its data in the AAR); on iOS the Swift package's `SpeechwarpVoiceEspeak`
sources, eSpeak NG as a static xcframework and its data (1.2 MB) as a resource bundle, all copied into the npm package
when it is packed (`scripts/vendor.sh`, which needs eSpeak built first: see [Voices](../../../docs/voices.md#building-the-native-parts)).
