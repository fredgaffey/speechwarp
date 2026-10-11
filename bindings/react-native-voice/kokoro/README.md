# react-native-speechwarp-voice-kokoro

[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), a neural voice, on ONNX Runtime's CPU, for
[react-native-speechwarp-voice](../README.md), with the catalogue of its model files.

```sh
npm install react-native-speechwarp-voice react-native-speechwarp-voice-kokoro
npm install react-native-speechwarp-voice-espeak     # the phonemizer: GPL-3.0-or-later, see below
```

**Kokoro needs a phonemizer** (text to IPA), and the only one shipped is eSpeak NG's, in
[react-native-speechwarp-voice-espeak](../espeak/README.md), which is **GPL-3.0-or-later**. Without it, or a phonemizer
the app sets natively (`VoiceProviders.phonemizer` in Kotlin or Swift), a Kokoro voice fails to start and the reader
reports why.

**iOS:** ONNX Runtime is about 60 MB, so Kokoro's engine is compiled only when asked for. In the Podfile:

```ruby
ENV['SPEECHWARP_KOKORO'] = '1'          # at the top

target 'YourApp' do
  config = use_native_modules!
  pod 'onnxruntime-objc', :modular_headers => true   # Swift imports it
  # ...
```

Without that, the pod holds only the catalogue and `kokoro.engineIncluded()` is false. Android always includes the
engine (ONNX Runtime's AAR, CPU only).

## The model files

The package never uses the network. The app downloads what `kokoro.missingFiles(voice)` lists into
`kokoro.directory()`, checks each SHA-256, and then reads with "kokoro:af_heart":

```ts
import { createReader } from 'react-native-speechwarp-voice';
import { kokoro } from 'react-native-speechwarp-voice-kokoro';

for (const file of kokoro.missingFiles('af_heart')) {
  // file.url, file.sha256, file.size; save it at `${kokoro.directory()}/${file.path}`
}
if (kokoro.isInstalled('af_heart')) {
  const reader = await createReader(text, kokoro.voiceId('af_heart'));
}
```

- `kokoro.catalogue()`: the repository and fixed revision, the model's variants, the tokenizer and 54 voices, each
  with its size, URL and SHA-256.
- `kokoro.directory()` is `speechwarp-kokoro` in the app's own files (Application Support on iOS), which the system
  does not clear; `kokoro.setDirectory(path)` moves it.
- `kokoro.modelFile()`: `model.onnx` (fp32, 326 MB) on Android and `model_fp16.onnx` (163 MB) on iOS, the defaults of
  the native libraries; `kokoro.setModelFile(name)` picks another (`model_q8f16.onnx` is 86 MB). Why: [Which model on
  Android](../../../docs/voices.md#which-model-on-android).
- `listVoices()` lists Kokoro's voices with `installed` true once their files are there, and `keepsSpoken` true:
  Kokoro is slow enough on a phone that its audio is kept on disk and spoken far ahead.

It is a thin layer over speechwarp's Kokoro libraries: on Android `io.github.fredgaffey:speechwarp-voice-kokoro` from
Maven Central (ONNX Runtime 1.23.2); on iOS the Swift package's `SpeechwarpVoiceKokoro` sources, copied into the npm
package when it is packed (`scripts/vendor.sh`), with the CocoaPod `onnxruntime-objc` 1.20.0, the release the Swift
package uses.
