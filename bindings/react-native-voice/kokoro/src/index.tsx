// Kokoro-82M for react-native-speechwarp-voice. See README.md.
//
// The package never uses the network: the app downloads the files `kokoro.missingFiles(voice)` lists into
// `kokoro.directory()`, checks each SHA-256, and then reads with "kokoro:af_heart" and the like. Kokoro needs a
// phonemizer, and the only one shipped is eSpeak NG's (react-native-speechwarp-voice-espeak, GPL-3.0-or-later).
import Native, {
  type KokoroCatalogue,
  type KokoroFile,
  type KokoroModel,
  type KokoroVoice,
} from './NativeSpeechwarpVoiceKokoro';

export type { KokoroCatalogue, KokoroFile, KokoroModel, KokoroVoice };

function native() {
  if (!Native) {
    throw new Error('react-native-speechwarp-voice-kokoro is not linked: rebuild the app (pod install on iOS)');
  }
  return Native;
}

let catalogue: KokoroCatalogue | undefined;

export const kokoro = {
  /** Whether this package's native code is in the app. */
  available(): boolean {
    return Native != null;
  },
  /** Whether this build can speak with Kokoro: on iOS only when built with SPEECHWARP_KOKORO=1 (see README.md). */
  engineIncluded(): boolean {
    return Native != null && Native.engineIncluded();
  },
  /** Every file there is: the model's variants, the tokenizer and the voices, with sizes, URLs and SHA-256. */
  catalogue(): KokoroCatalogue {
    catalogue ??= native().catalogue();
    return catalogue;
  },
  directory(): string {
    return native().directory();
  },
  setDirectory(path: string): void {
    if (!path) throw new TypeError('path must not be empty');
    native().setDirectory(path);
  },
  modelFile(): string {
    return native().modelFile();
  },
  /** One of `catalogue().models[i].file.path`, such as "model_q8f16.onnx". */
  setModelFile(fileName: string): void {
    if (!fileName) throw new TypeError('fileName must not be empty');
    native().setModelFile(fileName);
  },
  /** What is still to download for `voice` ("af_heart") with the current model file. */
  missingFiles(voice: string): KokoroFile[] {
    return native().missingFiles(voice);
  },
  isInstalled(voice: string): boolean {
    return native().isInstalled(voice);
  },
  hasPhonemizer(): boolean {
    return native().hasPhonemizer();
  },
  /** The id for createReader and setVoice: "kokoro:af_heart". */
  voiceId(voice: string): string {
    if (!voice) throw new TypeError('voice must not be empty');
    return `kokoro:${voice}`;
  },
};
