import Foundation
import KokoroSwift
import Metal
import MLX

// A C interface to Kokoro on the GPU, for apps that are not written in Swift (the Speechwarp.Voice.Kokoro.Gpu NuGet
// package calls it through function pointers): open the model, speak a text in a voice given as its raw style file
// (Kokoro's voices/NAME.bin: 510 x 256 float32, the same files ONNX Runtime uses), free what was returned, close.
//
// Calls on one handle must not overlap; the caller serialises them. They may come from any thread, including threads
// the Objective-C runtime knows nothing about (.NET's), so each call drains its own autorelease pool: Metal autoreleases
// command buffers and such, and a thread without a pool would keep them until it ends.
//
// Failures are reported, never fatal where that can be helped: MLX's errors are turned into Swift errors (otherwise MLX
// ends the process), and a message goes into the caller's buffer.

private final class Engine {
  let tts: KokoroTTS
  var voices: [String: MLXArray] = [:]
  init(tts: KokoroTTS) { self.tts = tts }
}

/// MLX keeps freed GPU buffers for reuse, by default up to the device's whole recommended working set. A phone has
/// less to spare: a sentence needs tens of megabytes, so keep that much and give the rest back.
private let cacheLimit = 64 * 1024 * 1024

private func report(_ message: String, _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) {
  guard let buffer, capacity > 0 else { return }
  let bytes = Array(message.utf8.prefix(Int(capacity) - 1))
  for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
  buffer[bytes.count] = 0
}

/// Opens the model (kokoro-v1_0.safetensors). Returns a handle, or nil with a message in `message` (at most `capacity`
/// bytes including the terminating zero; `message` may be null). Takes seconds: it reads the model, about 330 MB, and
/// misaki's dictionaries.
@_cdecl("speechwarp_kokoro_gpu_open")
public func speechwarp_kokoro_gpu_open(_ modelPath: UnsafePointer<CChar>, _ message: UnsafeMutablePointer<CChar>?,
                                       _ capacity: Int32) -> UnsafeMutableRawPointer? {
  autoreleasepool {
    let url = URL(fileURLWithPath: String(cString: modelPath))
    // KokoroTTS loads the weights with try!, so a missing file would end the process.
    guard FileManager.default.fileExists(atPath: url.path) else {
      report("No model at \(url.path).", message, capacity)
      return nil
    }
    // Without a Metal device (the simulator on some Macs, a process refused the GPU) MLX would abort on first use.
    guard MTLCreateSystemDefaultDevice() != nil else {
      report("This device has no Metal GPU.", message, capacity)
      return nil
    }
    Memory.cacheLimit = cacheLimit
    do {
      let tts = try withError { KokoroTTS(modelPath: url) }
      return Unmanaged.passRetained(Engine(tts: tts)).toOpaque()
    } catch {
      report("Kokoro's model could not be loaded: \(error)", message, capacity)
      return nil
    }
  }
}

/// Speaks `text` in the voice whose style file is `voicePath`, in British English if `british` is non-zero, at `speed`
/// (1 is normal). Writes the 24 kHz mono samples' address and count; free them with speechwarp_kokoro_gpu_free.
/// Returns 0, or -1 with a message in `message`. Text too long for the model in one go is spoken in parts.
@_cdecl("speechwarp_kokoro_gpu_speak")
public func speechwarp_kokoro_gpu_speak(_ handle: UnsafeMutableRawPointer, _ voicePath: UnsafePointer<CChar>,
                                        _ text: UnsafePointer<CChar>, _ british: Int32, _ speed: Float,
                                        _ samples: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                                        _ count: UnsafeMutablePointer<Int32>,
                                        _ message: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
  samples.pointee = nil
  count.pointee = 0
  return autoreleasepool {
    let engine = Unmanaged<Engine>.fromOpaque(handle).takeUnretainedValue()
    let path = String(cString: voicePath)
    let voice: MLXArray
    if let known = engine.voices[path] {
      voice = known
    } else {
      guard let data = FileManager.default.contents(atPath: path), data.count == 510 * 256 * 4 else {
        report("\(path) is missing or is not a Kokoro voice (510 x 256 floats).", message, capacity)
        return -1
      }
      let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
      voice = MLXArray(floats, [510, 1, 256])
      engine.voices[path] = voice
    }
    do {
      let audio = try withError {
        try speakInParts(engine.tts, voice, british != 0 ? .enGB : .enUS, String(cString: text), speed)
      }
      let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, audio.count))
      audio.withUnsafeBufferPointer { buffer.initialize(from: $0.baseAddress!, count: audio.count) }
      samples.pointee = buffer
      count.pointee = Int32(audio.count)
      return 0
    } catch {
      report("Kokoro on the GPU could not speak that: \(error)", message, capacity)
      return -1
    }
  }
}

/// The longest text spoken in one go. MLX's memory grows with the length of the audio: measured on a Mac, about 1.3 GB
/// for a 60-character sentence and 2.6 GB for 380 characters (the model and misaki take about 1 GB of it), more than an
/// iPhone allows an app. Longer text is spoken in parts, cut between phrases where it can be.
private let maxCharacters = 200

/// Speaks the text whole if it is short enough, otherwise each half in turn (see `cut`). Also halves text that has more
/// tokens than the model takes.
private func speakInParts(_ tts: KokoroTTS, _ voice: MLXArray, _ language: Language, _ text: String,
                          _ speed: Float) throws -> [Float] {
  let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
  if characters.isEmpty { return [] }
  if characters.count > maxCharacters {
    let at = cut(characters)
    return try speakInParts(tts, voice, language, String(characters[..<at]), speed)
      + speakInParts(tts, voice, language, String(characters[at...]), speed)
  }
  do {
    let audio = try tts.generateAudio(voice: voice, language: language, text: String(characters), speed: speed).0
    // Give back what this part used before the next one, rather than keep it for reuse: on a phone memory is short.
    Memory.clearCache()
    return audio
  } catch KokoroTTS.KokoroTTSError.tooManyTokens {
    guard characters.count > 1 else { return [] }
    let at = cut(characters)
    return try speakInParts(tts, voice, language, String(characters[..<at]), speed)
      + speakInParts(tts, voice, language, String(characters[at...]), speed)
  }
}

/// Where to cut text in two: after the punctuation nearest the middle, within the middle 60%; otherwise after the space
/// nearest the middle; otherwise in the middle.
private func cut(_ characters: [Character]) -> Int {
  let middle = characters.count / 2
  func nearest(within reach: Int, _ matches: (Character) -> Bool) -> Int? {
    for distance in 0 ... reach {
      for i in [middle + distance, middle - distance] where i > 0 && i < characters.count - 1 && matches(characters[i]) {
        return i + 1
      }
    }
    return nil
  }
  return nearest(within: characters.count * 3 / 10) { $0.isPunctuation }
    ?? nearest(within: middle) { $0.isWhitespace }
    ?? middle
}

/// Frees samples returned by speechwarp_kokoro_gpu_speak. Null is allowed.
@_cdecl("speechwarp_kokoro_gpu_free")
public func speechwarp_kokoro_gpu_free(_ samples: UnsafeMutablePointer<Float>?) {
  samples?.deallocate()
}

/// Closes a handle from speechwarp_kokoro_gpu_open and gives back MLX's cached GPU memory.
@_cdecl("speechwarp_kokoro_gpu_close")
public func speechwarp_kokoro_gpu_close(_ handle: UnsafeMutableRawPointer) {
  autoreleasepool {
    Unmanaged<Engine>.fromOpaque(handle).release()
    Memory.clearCache()
  }
}

