// Checks the JavaScript half against a stand-in for the native module: argument checking, what is passed across, and
// the routing of events to the reader they belong to. The native half is exercised by the example app.
import { beforeEach, describe, expect, it, jest } from '@jest/globals';

type Listener = (event: any) => void;
const emitters: { state: Listener[]; error: Listener[] } = { state: [], error: [] };
let nextHandle = 1;

const mockNative = {
  listVoices: jest.fn(async () => [
    { id: 'apple:x', name: 'X', language: 'en-US', engine: 'apple', installed: true, requiresNetwork: false, keepsSpoken: false },
  ]),
  createReader: jest.fn(async (_text: string, voiceId: string, _options: object) => ({
    handle: nextHandle++,
    sampleRate: 22050,
    duration: 3,
    sentenceCount: 2,
    voiceId,
  })),
  play: jest.fn(),
  pause: jest.fn(),
  seekToCharacter: jest.fn(),
  seekToTime: jest.fn(),
  setSpeed: jest.fn(),
  setVoice: jest.fn(),
  configure: jest.fn(),
  setSpeakAheadToDisk: jest.fn(),
  getState: jest.fn((handle: number) => ({
    reader: handle, character: 5, sentence: 0, time: 0.3, waiting: false, playing: true, finished: false,
  })),
  getSentences: jest.fn(() => [
    { start: 0, length: 10 },
    { start: 11, length: 9 },
  ]),
  releaseReader: jest.fn(),
  defaultCacheDirectory: jest.fn(() => '/caches/speechwarp-voice'),
  onState: jest.fn((listener: Listener) => {
    emitters.state.push(listener);
    return { remove: jest.fn() };
  }),
  onError: jest.fn((listener: Listener) => {
    emitters.error.push(listener);
    return { remove: jest.fn() };
  }),
};

jest.mock('../NativeSpeechwarpVoice', () => ({
  __esModule: true,
  get default() {
    return mockNative;
  },
}));

// eslint-disable-next-line import/first
import { chooseVoice, createReader, defaultCacheDirectory, listVoices, type VoiceInfo } from '../index';

const voice = (engine: string, language: string, extra: Partial<VoiceInfo> = {}): VoiceInfo => ({
  id: `${engine}:${language}`, name: language, language, engine, installed: true, requiresNetwork: false,
  keepsSpoken: false, ...extra,
});

beforeEach(() => {
  jest.clearAllMocks();
});

describe('createReader', () => {
  it('passes the text, voice and options across and keeps what comes back', async () => {
    const reader = await createReader('One. Two.', 'apple:x', { speed: 2, cache: false });
    expect(mockNative.createReader).toHaveBeenCalledWith('One. Two.', 'apple:x', { speed: 2, cache: false });
    expect(reader.sampleRate).toBe(22050);
    expect(reader.duration).toBe(3);
    expect(reader.sentenceCount).toBe(2);
    expect(reader.voiceId).toBe('apple:x');
    expect(reader.text).toBe('One. Two.');
  });

  it('refuses bad arguments before crossing', async () => {
    await expect(createReader('x', '')).rejects.toThrow(TypeError);
    await expect(createReader('x', 'apple:x', { speed: 0 })).rejects.toThrow(RangeError);
    await expect(createReader('x', 'apple:x', { lookahead: Number.NaN })).rejects.toThrow(RangeError);
    await expect(createReader('x', 'apple:x', { secondsPerCharacter: 0 })).rejects.toThrow(RangeError);
    expect(mockNative.createReader).not.toHaveBeenCalled();
  });
});

describe('Reader', () => {
  it('sends commands with its handle', async () => {
    const reader = await createReader('One. Two.', 'apple:x');
    const handle = (await (mockNative.createReader.mock.results[0]!.value as Promise<{ handle: number }>)).handle;
    reader.play();
    reader.pause();
    reader.seek(11.4);
    reader.seekToTime(1.5);
    reader.setSpeed(3);
    reader.setVoice('espeak:en-gb');
    reader.configure({ nonlinear: 0, pauseCap: 0.06 });
    reader.setSpeakAheadToDisk(true);
    expect(mockNative.play).toHaveBeenCalledWith(handle);
    expect(mockNative.pause).toHaveBeenCalledWith(handle);
    expect(mockNative.seekToCharacter).toHaveBeenCalledWith(handle, 11);
    expect(mockNative.seekToTime).toHaveBeenCalledWith(handle, 1.5);
    expect(mockNative.setSpeed).toHaveBeenCalledWith(handle, 3);
    expect(mockNative.setVoice).toHaveBeenCalledWith(handle, 'espeak:en-gb');
    expect(mockNative.configure).toHaveBeenCalledWith(handle, { nonlinear: 0, pauseCap: 0.06 });
    expect(mockNative.setSpeakAheadToDisk).toHaveBeenCalledWith(handle, true);
    expect(reader.voiceId).toBe('espeak:en-gb');
    expect(reader.state.character).toBe(5);
  });

  it('checks values', async () => {
    const reader = await createReader('x', 'apple:x');
    expect(() => reader.setSpeed(0.01)).toThrow(RangeError);
    expect(() => reader.seek(Number.POSITIVE_INFINITY)).toThrow(RangeError);
    expect(() => reader.configure({ pauseCap: Number.NaN })).toThrow(RangeError);
    expect(() => reader.setVoice('')).toThrow(TypeError);
  });

  it('asks for the sentences once', async () => {
    const reader = await createReader('One. Two.', 'apple:x');
    expect(reader.sentences).toEqual([
      { start: 0, length: 10 },
      { start: 11, length: 9 },
    ]);
    expect(reader.sentences).toBe(reader.sentences);
    expect(mockNative.getSentences).toHaveBeenCalledTimes(1);
  });

  it('gives each reader its own events, until removed or released', async () => {
    const a = await createReader('a', 'apple:x');
    const b = await createReader('b', 'apple:x');
    const handleOf = (i: number) => mockNative.createReader.mock.results[i]!.value as Promise<{ handle: number }>;
    const [ha, hb] = [(await handleOf(0)).handle, (await handleOf(1)).handle];
    const seenA: number[] = [];
    const seenB: number[] = [];
    const errors: string[] = [];
    const subscription = a.addListener('state', (e) => seenA.push(e.character));
    b.addListener('state', (e) => seenB.push(e.character));
    a.addListener('error', (e) => errors.push(e.message));
    const emit = (kind: 'state' | 'error', event: object) => emitters[kind].forEach((l) => l(event));
    emit('state', { reader: ha, character: 1 });
    emit('state', { reader: hb, character: 2 });
    emit('error', { reader: ha, message: 'no voice' });
    expect(seenA).toEqual([1]);
    expect(seenB).toEqual([2]);
    expect(errors).toEqual(['no voice']);
    subscription.remove();
    emit('state', { reader: ha, character: 3 });
    expect(seenA).toEqual([1]);
    b.release();
    emit('state', { reader: hb, character: 4 });
    expect(seenB).toEqual([2]);
    expect(mockNative.releaseReader).toHaveBeenCalledWith(hb);
  });

  it('cannot be used after release, and releases once', async () => {
    const reader = await createReader('x', 'apple:x');
    reader.release();
    reader.release();
    expect(mockNative.releaseReader).toHaveBeenCalledTimes(1);
    expect(() => reader.play()).toThrow(/released/);
  });
});

describe('voices', () => {
  it('lists them', async () => {
    expect((await listVoices())[0]!.id).toBe('apple:x');
  });

  it('chooses an installed offline voice for the language, by engine', () => {
    const voices = [
      voice('kokoro', 'en-us', { installed: false }),
      voice('android', 'en-US', { requiresNetwork: true }),
      voice('espeak', 'en-gb'),
      voice('android', 'de-DE'),
      voice('android', 'en-GB'),
    ];
    expect(chooseVoice(voices, 'en')?.id).toBe('android:en-GB');
    expect(chooseVoice(voices, 'en', ['espeak', 'android'])?.id).toBe('espeak:en-gb');
    expect(chooseVoice(voices, 'en_GB')?.id).toBe('android:en-GB');
    expect(chooseVoice(voices, 'fr')).toBeUndefined();
  });

  it('reports the cache directory', () => {
    expect(defaultCacheDirectory()).toBe('/caches/speechwarp-voice');
  });
});
