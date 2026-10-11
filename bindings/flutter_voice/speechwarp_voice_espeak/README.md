# speechwarp_voice_espeak

> **Licensed under the GPL-3.0-or-later**, unlike the rest of speechwarp, because eSpeak NG is. An app that includes
> this package must be distributed under the GPL-3.0, with its complete source.

[eSpeak NG](https://github.com/espeak-ng/espeak-ng) 1.52.0 for [`speechwarp_voice`](https://pub.dev/packages/speechwarp_voice)
on Android and iOS. With this package in the app:

- `VoiceReader` reads "espeak:" voices: `espeak:en-us`, `espeak:en-gb`, `espeak:en-gb-x-rp` and the other English
  accents, with a variant after a "+" (`espeak:en-us+klatt`), or at a rate and pitch (`espeak:en-gb/220/50`, words a
  minute and 0 to 100). eSpeak is far faster than listening, crisp at high speeds, and robotic.
- `VoiceReader.listVoices` lists them.
- Kokoro ([`speechwarp_voice_kokoro`](https://pub.dev/packages/speechwarp_voice_kokoro)) uses eSpeak NG as its
  phonemizer.

Nothing needs calling. `Espeak.version()` and `Espeak.phonemes(text)` let an app check that it is there.

It wraps speechwarp's eSpeak libraries (Kotlin `speechwarp-voice-espeak`, Swift `SpeechwarpVoiceEspeak`), with
eSpeak's English data (about 1.2 MB).

## Platforms

- **Android 7.0 (API 24) or later**: the library comes from Maven Central (`io.github.fredgaffey:speechwarp-voice-espeak`,
  four ABIs). The first use copies eSpeak's data into the app's files folder.
- **iOS: only from a checkout of the speechwarp repository in which eSpeak NG has been built.** speechwarp's Swift
  package gets eSpeak as a framework that is built locally, not from git:
  ```sh
  git submodule update --init --checkout third_party/espeak-ng
  bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift
  swift package purge-cache
  ```
  and the app depends on the packages by path or git from that checkout. Anywhere else (from pub.dev, say) the
  package still builds on iOS, but without eSpeak: `listVoices` has no eSpeak voices, an "espeak:" voice fails with a
  message that says why, and Kokoro finds no phonemizer.

## Licence

GPL-3.0-or-later (see LICENSE), as eSpeak NG, whose copyright notices are in
[its repository](https://github.com/espeak-ng/espeak-ng).
