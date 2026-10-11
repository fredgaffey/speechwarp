// Text read aloud by any voice, sped up by speechwarp, played natively. See README.md.
import Native, {
  type ReaderError,
  type ReaderInfo,
  type ReaderOptions,
  type ReaderState,
  type Sentence,
  type StreamSettings,
  type VoiceInfo,
} from './NativeSpeechwarpVoice';

export type { ReaderError, ReaderOptions, ReaderState, Sentence, StreamSettings, VoiceInfo };

/** A subscription to a reader's events; `remove()` ends it. */
export type Subscription = { remove(): void };

type Events = {
  /** The place being heard, every `positionInterval` while playing, and at once on play, pause, seek and the end. */
  state: ReaderState;
  /** A sentence could not be spoken (it is skipped) or a voice could not be made (the old one carries on). */
  error: ReaderError;
};

const listeners = { state: new Map<number, Set<(e: ReaderState) => void>>(), error: new Map<number, Set<(e: ReaderError) => void>>() };
let nativeSubscriptions: Subscription[] | null = null;

function dispatch<K extends keyof Events>(kind: K, event: Events[K]) {
  const forReader = listeners[kind].get(event.reader) as Set<(e: Events[K]) => void> | undefined;
  forReader?.forEach((listener) => listener(event));
}

// One native subscription per kind for every reader; events carry the reader's handle.
function subscribeNative() {
  if (nativeSubscriptions) return;
  nativeSubscriptions = [
    Native.onState((e) => dispatch('state', e)),
    Native.onError((e) => dispatch('error', e)),
  ];
}

function finite(name: string, value: number, min = -Infinity) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min) {
    throw new RangeError(`${name} must be a finite number${min > -Infinity ? ` of at least ${min}` : ''}`);
  }
}

/** A text being read aloud. Make one with `createReader`; call `release()` when done with it. */
export class Reader {
  /** The text being read. */
  readonly text: string;
  /** Frames a second of what is played. */
  readonly sampleRate: number;
  /** The timeline's length in seconds: every character of the text at `secondsPerCharacter`, whatever the voice. */
  readonly duration: number;
  /** The number of sentences the text was cut into. */
  readonly sentenceCount: number;
  private readonly handle: number;
  private released = false;
  private voice: string;
  private sentenceList: Sentence[] | null = null;

  /** @internal Use createReader. */
  constructor(text: string, info: ReaderInfo) {
    this.text = text;
    this.handle = info.handle;
    this.sampleRate = info.sampleRate;
    this.duration = info.duration;
    this.sentenceCount = info.sentenceCount;
    this.voice = info.voiceId;
  }

  private get live(): number {
    if (this.released) throw new Error('This reader has been released');
    return this.handle;
  }

  /** The id of the voice reading, or of the voice last asked for. */
  get voiceId(): string {
    return this.voice;
  }

  /** Plays from where it is. */
  play(): void {
    Native.play(this.live);
  }

  pause(): void {
    Native.pause(this.live);
  }

  /** Continues from the start of the sentence holding `character` (a UTF-16 offset, as JavaScript counts). */
  seek(character: number): void {
    finite('character', character);
    Native.seekToCharacter(this.live, Math.round(character));
  }

  /** Continues from the start of the sentence at `seconds` on the timeline. */
  seekToTime(seconds: number): void {
    finite('seconds', seconds);
    Native.seekToTime(this.live, seconds);
  }

  /** speechwarp's speed: 2 plays twice as fast as the voice speaks. From 0.05 to 20. */
  setSpeed(speed: number): void {
    finite('speed', speed, 0.05);
    Native.setSpeed(this.live, speed);
  }

  /** Carries on in another voice (an id from listVoices) from the next sentence not yet started. */
  setVoice(voiceId: string): void {
    if (!voiceId) throw new TypeError('voiceId must not be empty');
    Native.setVoice(this.live, voiceId);
    this.voice = voiceId;
  }

  /** Changes speechwarp's other settings: nonlinear amount, pause cap, heard pause and the rest. */
  configure(settings: StreamSettings): void {
    for (const [name, value] of Object.entries(settings)) {
      if (typeof value === 'number') finite(name, value);
    }
    Native.configure(this.live, settings);
  }

  /** Lets a slow voice carry on speaking to disk beyond the lookahead (say, while the phone is charging). */
  setSpeakAheadToDisk(enabled: boolean): void {
    Native.setSpeakAheadToDisk(this.live, enabled);
  }

  /** Where it is now, without waiting for the next event. */
  get state(): ReaderState {
    return Native.getState(this.live);
  }

  /** The sentences, as UTF-16 ranges of the text, for highlighting. */
  get sentences(): readonly Sentence[] {
    this.sentenceList ??= Native.getSentences(this.live);
    return this.sentenceList;
  }

  /** Listens to the reader's events: 'state' (the place being heard) and 'error'. */
  addListener<K extends keyof Events>(event: K, listener: (e: Events[K]) => void): Subscription {
    const handle = this.live;
    subscribeNative();
    const map = listeners[event] as unknown as Map<number, Set<(e: Events[K]) => void>>;
    let set = map.get(handle);
    if (!set) map.set(handle, (set = new Set()));
    set.add(listener);
    return {
      remove: () => {
        set?.delete(listener);
        if (set?.size === 0) map.delete(handle);
      },
    };
  }

  /** Stops it and frees everything; the reader cannot be used afterwards. Safe to call twice. */
  release(): void {
    if (this.released) return;
    this.released = true;
    listeners.state.delete(this.handle);
    listeners.error.delete(this.handle);
    Native.releaseReader(this.handle);
  }
}

/**
 * Starts reading `text` with the voice `voiceId` (from listVoices): sentences are spoken ahead at once, and `play()`
 * plays them. Resolves once the first voice is made, which can take a moment (Android starts its engine; Kokoro
 * loads its model only when it first speaks).
 */
export async function createReader(text: string, voiceId: string, options: ReaderOptions = {}): Promise<Reader> {
  if (typeof text !== 'string') throw new TypeError('text must be a string');
  if (!voiceId) throw new TypeError('voiceId must not be empty');
  for (const name of ['speed', 'lookahead', 'keptLookahead', 'secondsPerCharacter', 'sampleRate', 'positionInterval'] as const) {
    const value = options[name];
    if (value !== undefined) finite(name, value, name === 'speed' ? 0.05 : 0);
  }
  if (options.secondsPerCharacter === 0) throw new RangeError('secondsPerCharacter must be more than 0');
  const info = await Native.createReader(text, voiceId, options);
  return new Reader(text, info);
}

/**
 * Every voice the app can read with: the system's (Apple's or Android's), and eSpeak NG's and Kokoro's when
 * react-native-speechwarp-voice-espeak and react-native-speechwarp-voice-kokoro are installed. Kokoro's voices are
 * listed with `installed: false` until their files are downloaded.
 */
export function listVoices(): Promise<VoiceInfo[]> {
  return Native.listVoices();
}

/**
 * A voice to start with: the first installed, offline voice for `language` ("en", "en-GB"), preferring the engines in
 * `engines` in that order. Undefined if there is none.
 */
export function chooseVoice(
  voices: readonly VoiceInfo[],
  language = 'en',
  engines: readonly string[] = ['apple', 'android', 'espeak', 'kokoro']
): VoiceInfo | undefined {
  const wanted = language.toLowerCase().replace('_', '-');
  const usable = voices.filter(
    (v) =>
      v.installed &&
      !v.requiresNetwork &&
      (v.language.toLowerCase().replace('_', '-') === wanted || v.language.toLowerCase().startsWith(`${wanted}-`))
  );
  const rank = (v: VoiceInfo) => {
    const i = engines.indexOf(v.engine);
    return i < 0 ? engines.length : i;
  };
  return [...usable].sort((a, b) => rank(a) - rank(b))[0];
}

/** Where slow voices' audio is kept unless createReader is told otherwise. */
export function defaultCacheDirectory(): string {
  return Native.defaultCacheDirectory();
}
