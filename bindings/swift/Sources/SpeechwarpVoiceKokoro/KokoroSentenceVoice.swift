// A Kokoro voice for the live reader and the voice cache of SpeechwarpVoice. The same as Speechwarp.Voice.Kokoro's
// KokoroSentenceVoice and IKokoroAccelerator in C#.
import Foundation
import SpeechwarpVoice

/// Another way to run Kokoro, tried before ONNX Runtime for each sentence (in C#, Speechwarp.Voice.Kokoro.Gpu supplies
/// one that runs on Apple GPUs through MLX). It can decline any sentence, and the CPU speaks that one instead.
///
/// Called from the same threads as `SentenceVoice.speak`; an implementation serialises what it must.
public protocol KokoroAccelerator: AnyObject {
    /// Speaks `text` in `voice`, or returns nil when it cannot just now (the app is in the background, the model is
    /// not downloaded): then ONNX Runtime speaks it. Throws only for a real failure.
    ///
    /// - Parameters:
    ///   - text: The text, not phonemes: an accelerator makes its own.
    ///   - voice: The voice's name, such as "af_heart".
    ///   - voiceFile: The voice's style file, voices/NAME.bin in the model directory.
    ///   - language: The voice's language, as `KokoroModels.language(of:)` says ("en-us", "en-gb").
    ///   - speed: 1 for the voice's own pace.
    /// - Returns: Mono samples at 24 kHz, -1 to 1, or nil to leave the sentence to the CPU.
    func trySpeak(_ text: String, voice: String, voiceFile: String, language: String, speed: Float) throws -> [Float]?
}

#if Kokoro && canImport(OnnxRuntimeBindings)
/// A Kokoro voice as a `SentenceVoice`, for the live reader and the voice cache: id "kokoro:NAME", 24 kHz, and kept
/// on disk (`keepsSpoken`), because a phone speaks it little faster than it is heard.
///
/// Each sentence goes to the accelerator first, when there is one, and otherwise (or when it declines) to a
/// `KokoroEngine` on ONNX Runtime. The engine is loaded when it is first needed, not by the initialiser. Several
/// voices can share one engine (the model is the large part) through the initialiser that takes one.
///
/// ```swift
/// let voice = try KokoroSentenceVoice(directory: modelDirectory, voice: "af_heart", phonemizer: EspeakPhonemizer())
/// let book = try VoicedText(text, voice: voice)
/// ```
public final class KokoroSentenceVoice: SentenceVoice, @unchecked Sendable {
    /// The prefix of every `id`: "kokoro:".
    public static let idPrefix = "kokoro:"

    /// The model directory.
    public let directory: String
    /// The voice's name, such as "af_heart".
    public let voice: String
    /// The pace, 1 for the voice's own (about 0.5 to 2 work). Any other pace is part of `id`.
    public let speed: Float

    private let accelerator: KokoroAccelerator?
    private let language: String
    private let voiceFile: String
    private let ownsEngine: Bool
    private let makeEngine: (() throws -> KokoroEngine)?
    private let lock = NSLock()
    private var engine: KokoroEngine?
    private var closed = false

    /// A voice with its own engine, loaded from `directory` when first needed.
    ///
    /// - Parameters:
    ///   - directory: The model directory (see `KokoroModels`).
    ///   - voice: The voice's name, such as "af_heart".
    ///   - phonemizer: Turns words into IPA, such as SpeechwarpVoiceEspeak's `EspeakPhonemizer`.
    ///   - modelFile: The model's file name in the directory; model_fp16.onnx by default.
    ///   - threads: CPU threads for one sentence; 0 (the default) for one a core.
    ///   - speed: The pace, 1 for the voice's own.
    ///   - accelerator: Tried before the engine for each sentence; none when nil.
    /// - Throws: `KokoroError.invalidVoiceName` for anything but a voice name.
    public init(directory: String, voice: String, phonemizer: Phonemizer,
                modelFile: String = KokoroModels.defaultModelFile, threads: Int = 0, speed: Float = 1,
                accelerator: KokoroAccelerator? = nil) throws {
        voiceFile = try KokoroModels.voicePath(directory, voice: voice)
        self.directory = directory
        self.voice = voice
        self.speed = speed
        self.accelerator = accelerator
        language = KokoroModels.language(of: voice)
        ownsEngine = true
        makeEngine = { try KokoroEngine(directory: directory, phonemizer: phonemizer, modelFile: modelFile, threads: threads) }
    }

    /// A voice that speaks with `engine`, which may be shared with other voices and is not closed by this one.
    ///
    /// - Throws: `KokoroError.invalidVoiceName` for anything but a voice name.
    public init(engine: KokoroEngine, voice: String, speed: Float = 1, accelerator: KokoroAccelerator? = nil) throws {
        voiceFile = try KokoroModels.voicePath(engine.directory, voice: voice)
        directory = engine.directory
        self.voice = voice
        self.speed = speed
        self.accelerator = accelerator
        language = KokoroModels.language(of: voice)
        ownsEngine = false
        makeEngine = nil
        self.engine = engine
    }

    /// "kokoro:" and the voice's name, such as "kokoro:af_heart"; at a pace other than 1, "/" and the pace follow
    /// ("kokoro:af_heart/1.2"), so that audio kept at one pace is never served for another.
    public var id: String {
        speed == 1 ? Self.idPrefix + voice : Self.idPrefix + voice + "/" + Self.format(speed)
    }

    /// 24,000 (`KokoroEngine.sampleRate`).
    public var sampleRate: Int { KokoroEngine.sampleRate }

    /// True: Kokoro on a phone is slow enough that what it speaks is worth keeping.
    public var keepsSpoken: Bool { true }

    /// Speaks `sentence`: on the accelerator if it takes it, otherwise on ONNX Runtime.
    ///
    /// - Returns: Mono samples at 24 kHz, -1 to 1; empty when there is nothing to say.
    public func speak(_ sentence: String) throws -> [Float] {
        if KokoroPhonemes.trim(sentence).isEmpty { return [] }
        if let accelerated = try accelerator?.trySpeak(sentence, voice: voice, voiceFile: voiceFile,
                                                        language: language, speed: speed) {
            return accelerated
        }
        return try loadedEngine().speak(sentence, voice: voice, speed: speed)
    }

    /// Frees the engine if this voice loaded it; a shared engine is left to its owner. The voice cannot speak on the
    /// CPU afterwards (`KokoroError.closed`). An engine of its own is also freed when the voice is released.
    public func close() {
        let engine: KokoroEngine? = lock.locked {
            closed = true
            return ownsEngine ? self.engine : nil
        }
        engine?.close()
    }

    private func loadedEngine() throws -> KokoroEngine {
        try lock.locked {
            if let engine { return engine }
            if closed { throw KokoroError.closed }
            let made = try makeEngine!()
            engine = made
            return made
        }
    }

    /// `speed` as C# formats it with "0.###" in the invariant culture: at most three decimals, no trailing zeros, a
    /// leading zero, a point.
    static func format(_ speed: Float) -> String {
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(speed))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#else
/// Kokoro on ONNX Runtime needs this package's trait "Kokoro"; see `KokoroEngine`.
@available(*, unavailable, message: "Turn on the speechwarp package's trait \"Kokoro\" (iOS and macOS) to get KokoroSentenceVoice")
public final class KokoroSentenceVoice {}
#endif
