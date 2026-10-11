#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// What can go wrong when an Apple voice speaks a sentence.
public enum AppleSentenceVoiceError: Error, Equatable {
    /// The system did not finish speaking within the voice's `timeout`.
    case timedOut
}

/// One of Apple's voices (Eloquence or any other installed voice) as a `SentenceVoice`, for `VoicedText` and
/// anything else that works with any engine.
///
/// ```swift
/// let voice = try AppleSentenceVoice(identifier: "com.apple.eloquence.en-US.Reed")
/// let samples = try voice.speak("Hello there.")   // mono, voice.sampleRate
/// ```
///
/// The system delivers speech on the main thread's run loop, so `speak` asks for it there and waits on the
/// calling thread. Call it from a background thread, as `VoicedText` does. Called on the main thread it does not
/// deadlock: it runs the main run loop until the speech is ready, which also lets other work queued for the main
/// thread run meanwhile, so avoid that where you can.
public final class AppleSentenceVoice: SentenceVoice, @unchecked Sendable {
    /// The prefix of every `id`: "apple:".
    public static let idPrefix = "apple:"

    /// The voice speaking.
    public let voice: SpeechVoice
    /// "apple:" and the system's identifier, such as "apple:com.apple.eloquence.en-US.Reed".
    public let id: String
    /// The rate the voice says it speaks at (22,050 for Eloquence and most others). Speech that comes back at
    /// another rate is converted to it.
    public let sampleRate: Int
    /// The system rate the voice speaks at (see `SpeechRate`).
    public let rate: Float
    /// How long `speak` waits for the system before giving up, in seconds. Default one minute.
    public var timeout: TimeInterval = 60

    private let renderer: SpeechRenderer

    /// A voice that speaks at the system rate `rate`.
    public init(voice: SpeechVoice, rate: Float = SpeechRate.normal) throws {
        renderer = try SpeechRenderer(voice: voice)
        self.voice = voice
        self.rate = rate
        id = Self.idPrefix + voice.identifier
        sampleRate = Self.sampleRate(of: voice.identifier)
    }

    /// The installed voice with this system identifier, given bare ("com.apple.eloquence.en-US.Reed") or as an
    /// `id` ("apple:com.apple.eloquence.en-US.Reed").
    public convenience init(identifier: String, rate: Float = SpeechRate.normal) throws {
        let bare = Self.bare(identifier)
        guard let voice = SpeechVoice(identifier: bare) else { throw SpeechVoiceError.voiceNotInstalled(bare) }
        try self.init(voice: voice, rate: rate)
    }

    /// The system identifier in `id`, with or without the "apple:" prefix.
    public static func bare(_ id: String) -> String {
        id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : id
    }

    /// Speaks `sentence` and waits for it; mono samples at `sampleRate`.
    public func speak(_ sentence: String) throws -> [Float] {
        if sentence.allSatisfy(\.isWhitespace) { return [] }
        let box = ResultBox()
        let renderer = self.renderer, rate = self.rate
        Task.detached {
            do {
                box.set(.success(try await renderer.render(sentence, rate: rate)))
            } catch {
                box.set(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        if Thread.isMainThread {
            // Waiting here would block the thread the speech arrives on: run its loop instead.
            while box.result == nil && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        } else {
            _ = box.done.wait(timeout: .now() + timeout)
        }
        guard let result = box.result else { throw AppleSentenceVoiceError.timedOut }
        let speech = try result.get()
        return speech.sampleRate == sampleRate
            ? speech.samples : Resampling.linear(speech.samples, from: speech.sampleRate, to: sampleRate)
    }

    /// The rate an installed voice says it speaks at; 22,050 where it does not say.
    static func sampleRate(of identifier: String) -> Int {
        let settings = AVSpeechSynthesisVoice(identifier: identifier)?.audioFileSettings
        let rate = (settings?[AVSampleRateKey] as? NSNumber)?.intValue ?? 0
        return rate > 0 ? rate : 22050
    }

    private final class ResultBox: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Result<RenderedSpeech, Error>?

        var result: Result<RenderedSpeech, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ result: Result<RenderedSpeech, Error>) {
            lock.lock()
            value = result
            lock.unlock()
            done.signal()
        }
    }
}

/// Converting mono audio from one sample rate to another.
enum Resampling {
    /// Linear interpolation: good enough for speech going from 22,050 to 24,000 and the like.
    static func linear<C: RandomAccessCollection>(_ samples: C, from source: Int, to target: Int) -> [Float]
    where C.Element == Float, C.Index == Int {
        guard source != target, !samples.isEmpty else { return Array(samples) }
        let base = samples.startIndex
        let count = Int(Int64(samples.count) * Int64(target) / Int64(source))
        return (0..<count).map { i in
            let x = Double(i) * Double(source) / Double(target)
            let j = Int(x), f = Float(x - Double(j))
            return j + 1 < samples.count
                ? samples[base + j] * (1 - f) + samples[base + j + 1] * f : samples[samples.endIndex - 1]
        }
    }
}
#endif
