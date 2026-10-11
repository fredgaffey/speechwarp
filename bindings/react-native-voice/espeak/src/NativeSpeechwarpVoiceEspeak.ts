import { TurboModuleRegistry, type TurboModule } from 'react-native';

// eSpeak NG's own calls. Its voices are read through react-native-speechwarp-voice (listVoices, createReader), which
// finds this package's native code by itself.
export interface Spec extends TurboModule {
  /** eSpeak NG's version, such as "1.52.0". */
  version(): string;
  /** The voice variants, such as "klatt" or "f3", to add to a language after "+" ("en-us+klatt"). */
  variants(): Promise<string[]>;
  /** eSpeak's IPA for `text` (what Kokoro is given). */
  phonemize(text: string, language: string): Promise<string>;
}

export default TurboModuleRegistry.get<Spec>('SpeechwarpVoiceEspeak');
