# speechwarp_voice_kokoro

[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), a neural voice, for
[`speechwarp_voice`](https://pub.dev/packages/speechwarp_voice) on iOS and Android. With this package in the app,
`VoiceReader` reads "kokoro:" voices (such as `kokoro:af_heart`, or `kokoro:af_heart/1.2` at another pace) and
`VoiceReader.listVoices` lists all 54, each `isInstalled` when its files are in the model folder.

It wraps speechwarp's Kokoro engines (Swift `SpeechwarpVoiceKokoro`, Kotlin `speechwarp-voice-kokoro`): ONNX Runtime
on the CPU. Kokoro is not much faster than listening (about 2x real time in the iOS simulator and 2.9x on an arm64 Android
emulator; not yet measured on a phone), so what it speaks is kept on disk and read from there next time (`ReaderOptions.cache`, on by default).

```dart
import 'package:speechwarp_voice/speechwarp_voice.dart';
import 'package:speechwarp_voice_kokoro/speechwarp_voice_kokoro.dart';

for (final file in await Kokoro.missingFiles(directory, voice: 'af_heart')) {
  // download file.url to '$directory/${file.relativePath}', and check its SHA-256 against file.sha256
}
final reader = await VoiceReader.create(text,
    voiceId: 'kokoro:af_heart', options: ReaderOptions(kokoroDirectory: directory));
```

- The package never uses the network. `Kokoro.catalogue()` lists every model variant and voice with its size, URL
  (Hugging Face, at a fixed revision) and SHA-256; `Kokoro.missingFiles` says what a folder still needs.
- The default model differs by platform: `model.onnx` (fp32, 326 MB) on Android, `model_fp16.onnx` (163 MB) on iOS.
  `ReaderOptions.kokoroModelFile` picks another; `model_q8f16.onnx` (86 MB) is the small one. Why they differ is in
  [Voices](https://github.com/fredgaffey/speechwarp/blob/main/docs/voices.md#which-model-on-android).
- Changing from one Kokoro voice to another loads the model again (a few seconds, in the background).

## Kokoro needs a phonemizer

Kokoro speaks phonemes, not text. The only phonemizer speechwarp ships is eSpeak NG's, in
[`speechwarp_voice_espeak`](https://pub.dev/packages/speechwarp_voice_espeak), which is **GPL-3.0-or-later**: add it
and Kokoro just works. An app that cannot be GPL supplies its own phonemizer natively, as `speechwarp_voice`'s README
shows (`SpeechwarpVoicePlugin.phonemizer`). Without either, making a Kokoro reader fails with a `PlatformException`
whose code is "kokoro", as it does without `kokoroDirectory`.

## Installing

Add it beside `speechwarp_voice`, at the same version. Android 7.0 (API 24) or later; it brings ONNX Runtime's Android
library. On iOS (13 or later) it is a Swift Package Manager plugin, as `speechwarp_voice` is, and links
ONNX Runtime 1.20.0 through speechwarp's Swift package trait `Kokoro`.

Run on an arm64 Android 16 emulator and the iOS 26.4 simulator with the fp16 model and eSpeak's phonemizer; not yet on
a phone.

## Licence

Apache-2.0. The Kokoro model is Apache-2.0 too; ONNX Runtime is MIT.
