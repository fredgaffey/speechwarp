# react-native-speechwarp-voice

Text read aloud in a React Native app, on iOS and Android, by the system's voices (or Kokoro and eSpeak NG), sped up by
[speechwarp](https://github.com/fredgaffey/speechwarp), with the character being spoken reported as it is heard. It
is a thin layer over speechwarp's native voice libraries: the Swift package's `SpeechwarpVoice` on iOS and the Android
library `io.github.fredgaffey:speechwarp-voice`. Everything happens natively: the speaking ahead, the speed-up and the
playing (AVAudioEngine on iOS, AudioTrack on Android). No audio crosses to JavaScript; commands go in and positions
come out.

Not an official Google product. Needs the New Architecture (the default since React Native 0.76), iOS 15.1 and
Android 7.0 (API 24) or later.

```sh
npm install react-native-speechwarp-voice
cd ios && pod install
```

```ts
import { chooseVoice, createReader, listVoices } from 'react-native-speechwarp-voice';

const voices = await listVoices();                 // every engine's voices
const voice = chooseVoice(voices, 'en');           // an installed, offline English voice
const reader = await createReader(text, voice!.id, { speed: 2 });

const subscription = reader.addListener('state', (s) => {
  highlight(reader.sentences[s.sentence]);         // { start, length } in the text, as JavaScript counts
  // s.character, s.time (seconds on the timeline), s.waiting, s.playing, s.finished
});
reader.addListener('error', (e) => console.warn(e.message));

reader.play();
reader.setSpeed(3);                                // speechwarp's speed-up, on top of the voice's own rate
reader.seek(reader.sentences[4]!.start);           // from the start of the sentence holding that character
reader.setVoice('espeak:en-gb');                   // from the next sentence not yet started
reader.configure({ pauseCap: 0.06 });              // speechwarp's other settings
reader.pause();
reader.release();                                  // when done
```

## What it does

- `listVoices()` lists the voices: Apple's ("apple:com.apple.eloquence.en-US.Reed" and the rest) or Android's
  ("android:en-us-x-iol-local"), and those of the engine packages below when they are installed. Each has `id`,
  `name`, `language`, `engine`, `installed`, `requiresNetwork` and `keepsSpoken`.
- `createReader(text, voiceId, options)` cuts the text into sentences and starts speaking them ahead, on a thread of
  its own: 30 s of listening ahead for a quick voice (`lookahead`), 120 s for a slow one (`keptLookahead`). It resolves
  once the first voice is made. Options: `speed`, `speedUp` (false: no speechwarp), `lookahead`, `keptLookahead`,
  `secondsPerCharacter`, `cache` and `cacheDirectory`, `speakAheadToDisk`, `sampleRate`, `positionInterval` (s between
  state events, default 0.1), `manageAudioSession` (iOS, default true) and `language` (Android's sentence rules).
- The reader's state events give the place being **heard**: on Android from the frames AudioTrack has played, on iOS
  from the frames handed to AVAudioEngine less the output's latency. `waiting` is true while playing has caught up with
  a slow voice.
- The timeline: every character of the text lasts `secondsPerCharacter` (1/17 s), whatever the voice and speed, so
  that a time is the same place in every voice. `duration`, `seekToTime(seconds)` and `state.time` use it.
- A slow voice's audio (Kokoro's) is kept on disk, 40 sentences to a file, and read from there next time; see
  [the voice cache](../../docs/voices.md#the-voice-cache).
- Commands that return nothing (`play`, `seek`, `setVoice` ...) run in order, but after the call returns; `state` and
  `sentences` answer at once.

On iOS, with `manageAudioSession` the reader sets the audio session to playback (spoken audio) when it plays, and
pauses when the session is interrupted (a call). Playing in the background needs the app's `audio` background mode, as
for any player. On Android the app handles audio focus.

## More engines

| Package | Voices | Licence |
|---|---|---|
| `react-native-speechwarp-voice` | Apple's or Android's own | Apache-2.0 |
| [`react-native-speechwarp-voice-espeak`](espeak/) | eSpeak NG ("espeak:en-gb"), and the phonemizer Kokoro needs | **GPL-3.0-or-later** |
| [`react-native-speechwarp-voice-kokoro`](kokoro/) | Kokoro-82M ("kokoro:af_heart"), a neural voice on the CPU | Apache-2.0 |

Install one and rebuild the app (`pod install`): its voices appear in `listVoices()` and `createReader` and
`setVoice` take them. Nothing needs registering. **Kokoro needs a phonemizer, and the only one shipped is eSpeak's**, so
in practice Kokoro needs the GPL package too. (A native app can set one of its own: `VoiceProviders.phonemizer` in
Kotlin or Swift.)

## How the native code gets in

- **Android:** the module depends on `io.github.fredgaffey:speechwarp-voice` from Maven Central, at this package's
  version.
- **iOS:** CocoaPods, as React Native uses, cannot use a Swift package from git without making every app use
  frameworks, and the eSpeak and Kokoro parts are not in the Swift package's git checkout as usable products (eSpeak's
  framework is built locally; Kokoro is behind a trait). So the pod compiles the Swift package's own sources, copied
  into the npm package when it is packed (`scripts/vendor.sh`), with the C library, as `react-native-speechwarp`
  does. The pod is called `SpeechwarpVoice`, so its Swift module has the Swift package's name.

## Building it here

```sh
yarn install                       # yarn 4, from .yarnrc.yml (corepack, or node .yarn/releases/yarn-4.11.0.cjs)
yarn typecheck
yarn test                          # the JavaScript, against stand-ins for the native modules

# Android: the example uses this repository's Android libraries from Maven Local.
(cd ../android && ./gradlew publishToMavenLocal)
yarn example android

# iOS: copy in the Swift and C sources, and eSpeak NG (built by
# bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift).
yarn prepare && yarn workspace react-native-speechwarp-voice-espeak prepare && yarn workspace react-native-speechwarp-voice-kokoro prepare
(cd example/ios && SPEECHWARP_KOKORO=1 pod install)
yarn example ios
```

The example reads a paragraph with the first English voice, highlights the sentence being heard, and has buttons for
speed, seeking, a new reader in another voice, and changing the voice of the reader from the next sentence.

What has been run: the JavaScript tests; the example on an Android 16 arm64 emulator (Android's voice, eSpeak and
Kokoro, with seeking, speed and a voice change mid-text) and on the iOS 26.4 simulator (Apple's voice, eSpeak and Kokoro,
and a change from Apple's voice to Kokoro mid-text). Not on a phone.
