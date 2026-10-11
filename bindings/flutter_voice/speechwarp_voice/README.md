# speechwarp_voice

Text read aloud on iOS and Android, sentence by sentence, by the system's voices (and optionally Kokoro or eSpeak NG),
sped up by [speechwarp](https://github.com/fredgaffey/speechwarp)'s nonlinear speed-up, with the character being
heard reported back to Dart. Made for listening fast: an audiobook or a long article at 3x and beyond.

It wraps speechwarp's native voice readers (the Swift `SpeechwarpVoice`, the Kotlin `speechwarp-voice`): they speak
ahead on a thread of their own, speed the audio up and play it (AVAudioEngine on iOS, AudioTrack on Android). The
audio never crosses to Dart; Dart drives the reader and gets its position.

```dart
import 'package:speechwarp_voice/speechwarp_voice.dart';

final voices = await VoiceReader.listVoices();
final reader = await VoiceReader.create(text,
    voiceId: voices.firstWhere((v) => v.language.startsWith('en')).id,
    options: const ReaderOptions(speed: 2.5));

reader.positions.listen((p) {
  final s = reader.sentences[p.sentence];   // highlight text.substring(s.start, s.end)
  // p.character, p.time, p.isPlaying, p.isWaiting, p.isFinished, p.error
});

await reader.play();
await reader.seek(text.indexOf('Chapter 2'));
await reader.setSpeed(4);
await reader.configure(const SpeedUpSettings(pauseCap: 0.06, speedFloor: 0.5));
await reader.setVoice('espeak:en-gb');     // from the next sentence not yet started
await reader.dispose();
```

## The reader

- `VoiceReader.create(text, voiceId:, options:)` makes a native reader for a voice from `listVoices()`. Nothing plays
  until `play()`.
- `play`, `pause`, `seek(character)` (from the start of that sentence), `seekToSentence`, `setSpeed` (0.05 to 20),
  `configure` (the other speechwarp settings: nonlinear amount, pause cap, speed floor, rhythm, heard pause, floor
  blend), `setVoice(id)` (from the next sentence not yet started; made on the reader's thread, so a slow voice does not
  hold anything up) and `dispose`.
- `positions` is a stream of `ReaderPosition`: about 20 a second while playing, and one after each call. Character
  positions are UTF-16 indices, as Dart's `String` uses. `time` places it on a timeline of the text's characters at
  `ReaderOptions.secondsPerCharacter` each, the same whatever the voice and speed.
- `isWaiting` means the next sentence is not spoken yet; the audio is silent until it is. The reader never stalls the
  audio to wait.
- `sentences` is the text cut into sentences by the platform's rules.
- `ReaderOptions`: the starting speed and speed-up settings, how far ahead to speak, and the cache directory, where
  the audio of a slow voice (Kokoro) is kept so that it is spoken only once (on by default, in the platform's cache
  folder).

## Voices

`VoiceReader.listVoices()` returns `VoiceInfo` (`id`, `name`, `language`, `engine`, `isInstalled`, `keepsSpoken`,
`details`):

| Engine | Ids | Where from |
|---|---|---|
| Apple's voices (iOS) | `apple:com.apple.voice.compact.en-US.Samantha` | built in; Settings > Accessibility > Spoken Content adds more, including Eloquence |
| Android's voices | `android:en-us-x-iol-local` | the text-to-speech engine; `isInstalled` is false for a voice not yet downloaded |
| Kokoro-82M | `kokoro:af_heart`, `kokoro:af_heart/1.2` (pace) | [`speechwarp_voice_kokoro`](https://pub.dev/packages/speechwarp_voice_kokoro), and a model the app downloads |
| eSpeak NG | `espeak:en-gb`, `espeak:en-gb/220/50` (words a minute, pitch) | [`speechwarp_voice_espeak`](https://pub.dev/packages/speechwarp_voice_espeak), **GPL-3.0-or-later** |

The engine packages are separate so that an app takes on eSpeak NG's licence, or ONNX Runtime's size, only by adding
them. Added, their voices simply appear here; nothing needs registering.

**Kokoro needs a phonemizer.** The only one speechwarp ships is eSpeak NG's, so with `speechwarp_voice_espeak` in the
app Kokoro just works. An app that cannot be GPL supplies its own, natively, before making a Kokoro reader:

```kotlin
// Android, in MainActivity.onCreate (any io.github.fredgaffey.speechwarp.voice.Phonemizer)
SpeechwarpVoicePlugin.phonemizer = MyPhonemizer()
```

```swift
// iOS, in the AppDelegate (any SpeechwarpVoice.Phonemizer)
SpeechwarpVoicePlugin.phonemizer = MyPhonemizer()
```

## Installing

```yaml
dependencies:
  speechwarp_voice: ^0.3.7
  speechwarp_voice_kokoro: ^0.3.7   # optional
  speechwarp_voice_espeak: ^0.3.7   # optional, GPL-3.0-or-later
```

Use the same version of all of them, and take them all from the same place (pub.dev, or all from git).

- **Flutter 3.44.2 or later.**
- **iOS 13 or later, through Swift Package Manager.** The plugin has no CocoaPods podspec: the Swift library it wraps
  is a Swift package. Swift Package Manager is on by default in current Flutter; if your app has turned it off, turn
  it back on (`flutter config --enable-swift-package-manager`, or `enable-swift-package-manager: true` under
  `flutter: config:` in the app's pubspec). Xcode 16.3 (Swift 6.1) or later.
  - The plugin depends on speechwarp's Swift package from GitHub at the same version, and asks for its trait
    `Kokoro`: a Swift Package Manager bug fails the build when one package that uses speechwarp turns a trait on and
    another, listed earlier, does not. So Xcode downloads ONNX Runtime (about 60 MB, once) even without Kokoro, though
    only `speechwarp_voice_kokoro` links it.
  - To keep playing in the background, add the `audio` background mode to the app's Info.plist. The plugin sets the
    audio session to playback, spoken audio, when it starts playing.
- **Android 7.0 (API 24) or later**, Flutter's own minimum. The plugin depends on `io.github.fredgaffey:speechwarp-voice`
  from Maven Central at the same version. Making a voice starts the text-to-speech service, which the plugin does on a
  background thread.

Neither platform handles audio focus or interruptions (a phone call) yet: pause the reader yourself.

## Building it here

The example reads a passage with any voice, highlights the sentence being heard, and has a speed slider; its
integration test is the plugin's real test.

```sh
# Android: the example takes speechwarp's Android libraries from this computer's Maven repository, so publish the
# repository's own there first (needs the eSpeak submodule: git submodule update --init --checkout third_party/espeak-ng)
(cd ../../android && ./gradlew publishToMavenLocal)

flutter test                                   # the Dart side, against a stand-in for the platform
cd example
flutter test integration_test -d <device>      # in the real app: system voices, eSpeak, Kokoro's catalogue
# with a Kokoro model on the device as well:
flutter test integration_test -d <device> --dart-define=KOKORO_DIR=<folder> --dart-define=KOKORO_MODEL=model_fp16.onnx
flutter run --dart-define=AUTOPLAY=true        # starts reading at once
```

On iOS the plugin builds against the Swift package at the top of this repository. eSpeak NG is there only once its
framework has been built (`bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift`, then
`swift package purge-cache` at the top); without it the example builds and its eSpeak test is skipped.

What has been run: the Dart tests; the integration test on an arm64 Android 16 emulator and on the iOS 26.4
simulator, with Apple's, Android's, eSpeak's and Kokoro's (fp16) voices. Not yet on a phone.

## Licence

Apache-2.0, as speechwarp. speechwarp packages Google's Speedy and the Sonic library; it is not an official Google
product. eSpeak NG, in `speechwarp_voice_espeak` only, is GPL-3.0-or-later.
