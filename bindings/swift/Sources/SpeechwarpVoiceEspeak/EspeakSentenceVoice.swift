// eSpeak NG as a sentence voice and a phonemizer, for the live reader and cache of SpeechwarpVoice and for Kokoro.
// GPL-3.0-or-later, as eSpeak NG is.
#if os(iOS) || os(macOS)
import Foundation
import SpeechwarpVoice

/// eSpeak NG's formant voice in one language or accent, as a sentence voice. Quick enough to speak as it is heard,
/// so nothing needs keeping.
public final class EspeakSentenceVoice: SentenceVoice {
    /// The voice, such as "en-gb" or "en-us+klatt".
    public let language: String
    /// Speaking rate in words a minute.
    public let wordsPerMinute: Int
    /// Pitch, 0 to 100.
    public let pitch: Int
    /// Frames a second of what `speak` returns: 22,050.
    public let sampleRate: Int

    /// A voice for `language` ("en-us", "en-gb", "en-gb-x-rp", "en-us+klatt"), at a rate and pitch. Throws if eSpeak
    /// cannot start (its data is missing).
    public init(language: String = "en-us", wordsPerMinute: Int = Espeak.defaultWordsPerMinute,
                pitch: Int = Espeak.defaultPitch) throws {
        self.language = language
        self.wordsPerMinute = wordsPerMinute
        self.pitch = pitch
        sampleRate = try Espeak.shared.sampleRate()
    }

    /// "espeak:" and the language, such as "espeak:en-gb"; at a rate or pitch other than the defaults these follow,
    /// as in "espeak:en-gb/220/50", so that cached audio is never taken for another rate's.
    public var id: String {
        wordsPerMinute == Espeak.defaultWordsPerMinute && pitch == Espeak.defaultPitch
            ? "espeak:\(language)" : "espeak:\(language)/\(wordsPerMinute)/\(pitch)"
    }

    public func speak(_ sentence: String) throws -> [Float] {
        try Espeak.shared.speak(sentence, language: language, wordsPerMinute: wordsPerMinute, pitch: pitch)
    }
}

/// eSpeak NG's text to phonemes (IPA), for a neural voice that needs phonemes, such as Kokoro. Thread-safe: it
/// shares the one eSpeak, whose calls take turns.
public final class EspeakPhonemizer: Phonemizer {
    public init() {}

    /// eSpeak's IPA for `text` in `language` ("en-us", "en-gb"), clauses separated by a space, as eSpeak gives it.
    public func phonemize(_ text: String, language: String) throws -> String {
        try Espeak.shared.phonemes(text, language: language)
    }
}
#endif
