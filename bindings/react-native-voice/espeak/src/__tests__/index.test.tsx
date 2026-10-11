import { describe, expect, it, jest } from '@jest/globals';

jest.mock('../NativeSpeechwarpVoiceEspeak', () => ({
  __esModule: true,
  default: { version: () => '1.52.0', variants: async () => ['klatt'], phonemize: async () => 'hɛlˈoʊ' },
}));

// eslint-disable-next-line import/first
import { espeakAvailable, espeakPhonemize, espeakVariants, espeakVersion, espeakVoiceId } from '../index';

describe('espeak', () => {
  it('builds voice ids as the native side reads them', () => {
    expect(espeakVoiceId('en-gb')).toBe('espeak:en-gb');
    expect(espeakVoiceId('en-us+klatt', 220)).toBe('espeak:en-us+klatt/220/50');
    expect(espeakVoiceId('en-gb', 175, 60)).toBe('espeak:en-gb/175/60');
    expect(() => espeakVoiceId('')).toThrow(TypeError);
    expect(() => espeakVoiceId('en', 200.5)).toThrow(RangeError);
  });

  it('passes calls to the native module', async () => {
    expect(espeakAvailable()).toBe(true);
    expect(espeakVersion()).toBe('1.52.0');
    expect(await espeakVariants()).toEqual(['klatt']);
    expect(await espeakPhonemize('hello')).toBe('hɛlˈoʊ');
  });
});
