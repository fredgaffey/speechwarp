import { describe, expect, it, jest } from '@jest/globals';

const file = { path: 'voices/af_heart.bin', size: 522240, url: 'https://example/af_heart.bin', sha256: 'd583' };
const mockNative = {
  catalogue: jest.fn(() => ({
    repository: 'onnx-community/Kokoro-82M-v1.0-ONNX', revision: 'r', defaultModelFile: 'model.onnx',
    defaultVoice: 'af_heart', tokenizer: file, models: [], voices: [{ name: 'af_heart', language: 'en-us', female: true, file }],
  })),
  directory: jest.fn(() => '/files/speechwarp-kokoro'),
  setDirectory: jest.fn((path: string) => path),
  modelFile: jest.fn(() => 'model.onnx'),
  setModelFile: jest.fn((name: string) => name),
  missingFiles: jest.fn(() => [file]),
  isInstalled: jest.fn(() => false),
  hasPhonemizer: jest.fn(() => true),
  engineIncluded: jest.fn(() => true),
};
jest.mock('../NativeSpeechwarpVoiceKokoro', () => ({
  __esModule: true,
  get default() {
    return mockNative;
  },
}));

// eslint-disable-next-line import/first
import { kokoro } from '../index';

describe('kokoro', () => {
  it('reads the catalogue once', () => {
    expect(kokoro.catalogue().voices[0]!.name).toBe('af_heart');
    kokoro.catalogue();
    expect(mockNative.catalogue).toHaveBeenCalledTimes(1);
  });

  it('passes the rest across', () => {
    expect(kokoro.available()).toBe(true);
    expect(kokoro.engineIncluded()).toBe(true);
    expect(kokoro.directory()).toBe('/files/speechwarp-kokoro');
    kokoro.setDirectory('/elsewhere');
    expect(mockNative.setDirectory).toHaveBeenCalledWith('/elsewhere');
    kokoro.setModelFile('model_q8f16.onnx');
    expect(mockNative.setModelFile).toHaveBeenCalledWith('model_q8f16.onnx');
    expect(kokoro.missingFiles('af_heart')).toEqual([file]);
    expect(kokoro.isInstalled('af_heart')).toBe(false);
    expect(kokoro.hasPhonemizer()).toBe(true);
    expect(kokoro.voiceId('af_heart')).toBe('kokoro:af_heart');
    expect(() => kokoro.setDirectory('')).toThrow(TypeError);
  });
});
