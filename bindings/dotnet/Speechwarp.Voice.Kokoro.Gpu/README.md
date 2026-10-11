# Speechwarp.Voice.Kokoro.Gpu

Kokoro-82M on the iPhone's GPU, through Apple's MLX ([mlalma/kokoro-ios](https://github.com/mlalma/kokoro-ios), with
[misaki](https://github.com/mlalma/MisakiSwift)'s English pronunciations), as an accelerator for
`Speechwarp.Voice.Kokoro`: each sentence goes to the GPU when it can and to ONNX Runtime on the CPU otherwise. Its
author measured about 3.3x real time on an iPhone 13 Pro, against 2.2x on the CPU. See the repository README.

**Optional and off by default.** Nothing touches the GPU unless the model directory holds a file named `use-gpu`.
It has not yet been shown to work on a phone: in the one test so far it started and produced no audio. Until that
is understood every call has a time limit (`KokoroGpu.Timeout`, 90 s), after which the CPU takes over for the rest of
the run.

## Requirements

- A real iPhone or iPad on iOS 18 or later. MLX needs a real GPU: **simulator builds leave the framework out** (the
  package's build targets embed it only when the runtime identifier is `ios-arm64`), `KokoroGpu.IsIncluded` is false
  there, and Kokoro speaks on the CPU.
- The model, `kokoro-v1_0.safetensors` (327 MB; `KokoroGpu.Model` has the URL and SHA-256), in the same model
  directory as the CPU's files; the voices are the same `voices/NAME.bin` files.
- English voices only (`a*` American, `b*` British).
- The app on screen. iOS refuses GPU work from an app in the background, and MLX ends the process when refused, so
  call `KokoroGpu.WatchAppState()` once at launch, on the main thread: no sentence starts on the GPU while the app is
  not active, and when the app is about to leave the screen its main thread waits (up to 8 s) for the sentence under
  way. Without that call the GPU is never used.

The package adds about 42 MB to a device build (one framework, `SpeechwarpKokoroGPU`, and four resource bundles: MLX's
shaders, Kokoro's configuration, misaki's dictionaries, ZIPFoundation's privacy manifest). Set the MSBuild property
`SpeechwarpKokoroGpu` to `false` to leave it out.

## Use

```csharp
using Speechwarp.Voice.Espeak;
using Speechwarp.Voice.Kokoro;
using Speechwarp.Voice.Kokoro.Gpu;

// At launch, on the main thread.
KokoroGpu.WatchAppState();
KokoroGpu.Log = line => Console.WriteLine(line);         // optional diagnostics

// A voice: the GPU while the app is on screen and the opt-in file is there, the CPU otherwise.
var gpu = new KokoroGpuAccelerator(directory);
using var voice = new KokoroSentenceVoice(directory, "af_heart", new EspeakPhonemizer(), accelerator: gpu);
float[] samples = voice.Speak("Hello there.");          // 24 kHz mono
```

`KokoroGpu.Speak` can also be called directly; it throws `GpuUnavailableException` whenever the CPU should be used
instead. `KokoroGpu.Close()` frees the model's memory.

## Building the framework

```sh
bindings/swift/KokoroGPU/build-frameworks.sh
```

It fetches kokoro-ios and MisakiSwift at pinned commits, builds them with MLX into one framework for iOS devices, and
writes it, the bundles and their licences to `native/ios-arm64/` (not in git). It needs Xcode's Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain` if `xcrun -f metal` finds nothing). Packing fails without it.

## Licences

This package is Apache-2.0. The framework contains kokoro-ios (MIT), MisakiSwift (Apache-2.0), mlx-swift and MLX
(MIT), MLXUtilsLibrary (Apache-2.0), swift-numerics (Apache-2.0) and ZIPFoundation (MIT); their licences are in the
package under `licenses/kokoro-gpu/`. The Kokoro-82M weights are Apache-2.0 (hexgrad); the app downloads them.
