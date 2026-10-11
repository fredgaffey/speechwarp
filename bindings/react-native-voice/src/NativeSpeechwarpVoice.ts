import { TurboModuleRegistry, type CodegenTypes, type TurboModule } from 'react-native';

// The native module. Use createReader and listVoices in index.tsx, not this.
//
// The reading, the speaking ahead, the speed-up and the playing are all native: VoicedText from the Swift package
// SpeechwarpVoice (iOS) or the Android library io.github.fredgaffey:speechwarp-voice, played by AVAudioEngine or
// AudioTrack. No audio crosses to JavaScript; only commands go in and positions come out.

/** A voice that can read. */
export type VoiceInfo = {
  /** What createReader and setVoice take, such as "apple:com.apple.eloquence.en-US.Reed". */
  id: string;
  name: string;
  /** A BCP 47 tag, such as "en-US". */
  language: string;
  /** "apple", "android", "espeak" or "kokoro". */
  engine: string;
  /** Ready to speak without anything more being downloaded. */
  installed: boolean;
  /** Needs the network to speak (some of Android's voices). */
  requiresNetwork: boolean;
  /** Slower than listening: its audio is kept on disk and spoken far ahead. */
  keepsSpoken: boolean;
};

export type ReaderOptions = {
  /** speechwarp's speed. Default 1. */
  speed?: number;
  /** False passes the voice's audio through without speechwarp (speed and configure then do nothing). */
  speedUp?: boolean;
  /** Seconds of listening spoken ahead for a quick voice. Default 30. */
  lookahead?: number;
  /** Seconds of listening spoken ahead for a slow voice. Default 120. */
  keptLookahead?: number;
  /** The timeline's pace: seconds a character. Default 1/17. */
  secondsPerCharacter?: number;
  /** Keep slow voices' audio on disk. Default true. */
  cache?: boolean;
  /** Where; default the voice cache's usual folder in the app's caches. */
  cacheDirectory?: string;
  /** Carry on speaking a slow voice to disk beyond the lookahead. Default false. */
  speakAheadToDisk?: boolean;
  /** Sample rate of the audio played; default the first voice's. */
  sampleRate?: number;
  /** Seconds between position events while playing. Default 0.1. */
  positionInterval?: number;
  /** iOS: set the audio session to playback (spoken audio) and activate it on play. Default true. */
  manageAudioSession?: boolean;
  /** Android: the language whose rules cut the text into sentences (BCP 47). Default the device's. */
  language?: string;
};

export type ReaderInfo = {
  handle: number;
  /** Frames a second of what is played. */
  sampleRate: number;
  /** The timeline's length in seconds: every character at secondsPerCharacter. */
  duration: number;
  sentenceCount: number;
  voiceId: string;
};

export type Sentence = {
  /** UTF-16 offset in the text, as JavaScript strings count. */
  start: number;
  length: number;
};

/** speechwarp's settings beyond the speed (see docs/api.md). Each is left as it is when not given. */
export type StreamSettings = {
  nonlinear?: number;
  pauseCap?: number;
  keepSpeed?: boolean;
  speedFloor?: number;
  rhythmGap?: number;
  rhythmRate?: number;
  /** With heardPauseFrom: heard pause in seconds, applied from that speed. */
  heardPause?: number;
  heardPauseFrom?: number;
  /** With floorBlendFrom and floorBlendFull. */
  floorBlend?: number;
  floorBlendFrom?: number;
  floorBlendFull?: number;
};

export type ReaderState = {
  reader: number;
  /** UTF-16 offset of what is being heard. */
  character: number;
  /** The sentence being heard. */
  sentence: number;
  /** Seconds on the timeline. */
  time: number;
  /** Playing has caught up with the voice: silence until the next sentence is spoken. */
  waiting: boolean;
  playing: boolean;
  /** Everything has been heard. */
  finished: boolean;
};

export type ReaderError = {
  reader: number;
  message: string;
};

export interface Spec extends TurboModule {
  /** Every voice of every engine installed in the app. */
  listVoices(): Promise<VoiceInfo[]>;
  /** Starts speaking ahead at once; plays only on play(). Makes the first voice, which can take a moment. */
  createReader(text: string, voiceId: string, options: ReaderOptions): Promise<ReaderInfo>;
  play(handle: number): void;
  pause(handle: number): void;
  /** Continues from the start of the sentence holding this UTF-16 offset. */
  seekToCharacter(handle: number, character: number): void;
  /** Continues from the start of the sentence at this time on the timeline. */
  seekToTime(handle: number, seconds: number): void;
  setSpeed(handle: number, speed: number): void;
  /** From the next sentence not yet started. */
  setVoice(handle: number, voiceId: string): void;
  configure(handle: number, settings: StreamSettings): void;
  setSpeakAheadToDisk(handle: number, enabled: boolean): void;
  getState(handle: number): ReaderState;
  getSentences(handle: number): Sentence[];
  /** Stops playing and speaking and frees everything. */
  releaseReader(handle: number): void;
  /** Where slow voices' audio is kept by default. */
  defaultCacheDirectory(): string;

  readonly onState: CodegenTypes.EventEmitter<ReaderState>;
  readonly onError: CodegenTypes.EventEmitter<ReaderError>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('SpeechwarpVoice');
