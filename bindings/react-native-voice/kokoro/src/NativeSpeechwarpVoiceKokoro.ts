import { TurboModuleRegistry, type TurboModule } from 'react-native';

// Kokoro's model files and where they are. Its voices are read through react-native-speechwarp-voice (listVoices,
// createReader), which finds this package's native code by itself.

export type KokoroFile = {
  /** Where it goes under the model directory, such as "voices/af_heart.bin". */
  path: string;
  size: number;
  url: string;
  sha256: string;
};

export type KokoroModel = {
  /** Such as "model_fp16". */
  id: string;
  name: string;
  description: string;
  file: KokoroFile;
};

export type KokoroVoice = {
  /** Such as "af_heart"; its id for createReader is "kokoro:af_heart". */
  name: string;
  language: string;
  female: boolean;
  file: KokoroFile;
};

export type KokoroCatalogue = {
  /** The Hugging Face repository and the fixed revision the files come from. */
  repository: string;
  revision: string;
  /** The model file used on this platform unless setModelFile says otherwise. */
  defaultModelFile: string;
  defaultVoice: string;
  tokenizer: KokoroFile;
  models: KokoroModel[];
  voices: KokoroVoice[];
};

export interface Spec extends TurboModule {
  catalogue(): KokoroCatalogue;
  /** The model directory (default: speechwarp-kokoro in the app's own files, which the system does not clear). */
  directory(): string;
  // Setters return the new value: a method returning nothing would run later, after calls made after it.
  setDirectory(path: string): string;
  /** The model file voices load, such as "model.onnx". */
  modelFile(): string;
  setModelFile(fileName: string): string;
  /** What is still to download for `voice` with the current model, in the current directory. */
  missingFiles(voice: string): KokoroFile[];
  isInstalled(voice: string): boolean;
  /** Whether a phonemizer is there for Kokoro (react-native-speechwarp-voice-espeak, or the app's own). */
  hasPhonemizer(): boolean;
  /** Whether this build can speak with Kokoro (iOS: only when built with SPEECHWARP_KOKORO=1). */
  engineIncluded(): boolean;
}

export default TurboModuleRegistry.get<Spec>('SpeechwarpVoiceKokoro');
