// eSpeak NG for react-native-speechwarp-voice. GPL-3.0-or-later, as eSpeak NG is: an app that includes this package
// must be distributed under the GPL-3.0 too, with its source. See README.md.
//
// Nothing needs calling: once the package is installed, listVoices lists eSpeak's voices ("espeak:en-gb", ...),
// createReader and setVoice take them, and Kokoro (react-native-speechwarp-voice-kokoro) uses eSpeak's phonemizer.
import Native from './NativeSpeechwarpVoiceEspeak';

const DEFAULT_WORDS_PER_MINUTE = 175;
const DEFAULT_PITCH = 50;

/** Whether this package's native code is in the app (false until the app is rebuilt after installing it). */
export function espeakAvailable(): boolean {
  return Native != null;
}

function native() {
  if (!Native) {
    throw new Error('react-native-speechwarp-voice-espeak is not linked: rebuild the app (pod install on iOS)');
  }
  return Native;
}

/** eSpeak NG's version, such as "1.52.0". */
export function espeakVersion(): string {
  return native().version();
}

/** The voice variants, such as "klatt" or "f3": `espeakVoiceId("en-us+klatt")`. */
export function espeakVariants(): Promise<string[]> {
  return native().variants();
}

/** eSpeak's IPA for `text` in `language` ("en-us", "en-gb"). */
export function espeakPhonemize(text: string, language = 'en-us'): Promise<string> {
  return native().phonemize(text, language);
}

/**
 * The id of an eSpeak voice for createReader and setVoice: "espeak:en-gb", or "espeak:en-gb/220/50" at another rate
 * (80 to 450 words a minute; default 175) or pitch (0 to 100; default 50).
 */
export function espeakVoiceId(
  language: string,
  wordsPerMinute = DEFAULT_WORDS_PER_MINUTE,
  pitch = DEFAULT_PITCH
): string {
  if (!language) throw new TypeError('language must not be empty');
  for (const [name, value] of [
    ['wordsPerMinute', wordsPerMinute],
    ['pitch', pitch],
  ] as const) {
    if (!Number.isInteger(value)) throw new RangeError(`${name} must be a whole number`);
  }
  return wordsPerMinute === DEFAULT_WORDS_PER_MINUTE && pitch === DEFAULT_PITCH
    ? `espeak:${language}`
    : `espeak:${language}/${wordsPerMinute}/${pitch}`;
}
