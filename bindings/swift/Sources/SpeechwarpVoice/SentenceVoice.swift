// The engine-independent face of text-to-speech, as in C# (Speechwarp.Voice.ISentenceVoice). An engine speaks
// one sentence at a time; the live reader and the cache work with any engine.

/// An engine that speaks one sentence at a time, at its own sample rate.
///
/// Called from one background thread at a time; `speak` may take as long as it needs.
public protocol SentenceVoice: AnyObject {
    /// Identifies the voice and engine, stable across runs, such as "apple:com.apple.eloquence.en-US.Reed",
    /// "kokoro:af_heart" or "espeak:en-gb". Cached audio is kept per voice id.
    var id: String { get }
    /// Frames a second of what `speak` returns. Mono.
    var sampleRate: Int { get }
    /// Speaks `sentence`; returns mono samples, -1 to 1 (empty for nothing to say).
    func speak(_ sentence: String) throws -> [Float]
    /// The engine is slower than listening: what it speaks is worth keeping on disk and speaking far ahead.
    var keepsSpoken: Bool { get }
}

public extension SentenceVoice {
    var keepsSpoken: Bool { false }
}

/// Turns text into phonemes (IPA) for a neural voice such as Kokoro.
public protocol Phonemizer: AnyObject {
    /// The IPA for `text` in `language` ("en-us", "en-gb"). Punctuation is handled by the caller.
    func phonemize(_ text: String, language: String) throws -> String
}
