#if canImport(AVFoundation) && canImport(NaturalLanguage) && canImport(CryptoKit)
import AVFoundation
import Foundation
import NaturalLanguage
import Speechwarp

/// A text read aloud by a system voice and sped up by speechwarp, rendered sentence by sentence a little ahead
/// of playback. A convenience over `VoicedText` with an `AppleSentenceVoice`; use `VoicedText` itself for other
/// engines, changing voice, a cache or seeking by time.
///
/// ```swift
/// let voice = SpeechVoice.eloquence(language: "en-US").first { $0.name == "Reed" }!
/// let book = try SpokenText(text, voice: voice)
/// book.speed = 5                                   // on top of the voice's own rate
/// book.configure { $0.setHeardPause(0.03, fromSpeed: 3) }
/// // on the audio thread:
/// let samples = book.read(maxFrames: 1024)         // mono, book.sampleRate
/// // for the display:
/// let at = book.characterPosition                  // UTF-16 offset into the text
/// ```
///
/// Rendering runs on the main thread's run loop (where the system delivers speech), waited for on the reader's
/// own thread; everything else is safe to call from any thread. `read` never waits: if the next sentence is not
/// rendered yet it returns what there is, and `isBuffering` says so.
public final class SpokenText: @unchecked Sendable {
    /// A sentence: its range in the text, in UTF-16 offsets (as `NSString` and most UI text APIs count).
    public struct Sentence: Equatable, Sendable {
        public let range: NSRange
        public let text: String
    }

    public var text: String { reader.text }
    public let voice: SpeechVoice
    public var sentences: [Sentence] { reader.sentences }
    /// The sample rate of what `read` returns. Mono.
    public var sampleRate: Int { reader.sampleRate }
    /// The reader doing the work, for what this class does not offer (seeking by time, say).
    public let reader: VoicedText

    private let lock = NSLock()
    private var rate: Float

    /// The system rate the voice speaks at (see `SpeechRate`). Applies to sentences rendered afterwards.
    public var voiceRate: Float {
        get { lock.locked { rate } }
        set {
            lock.locked {
                rate = newValue
                if let next = try? AppleSentenceVoice(voice: voice, rate: newValue) { reader.setVoice(next) }
            }
        }
    }

    /// speechwarp's speed on top of the voice's own rate: 2 plays twice as fast again.
    public var speed: Float {
        get { reader.speed }
        set { reader.speed = newValue }
    }

    /// Seconds of listening to keep rendered ahead of what is being heard. Default 30.
    public var lookahead: TimeInterval {
        get { reader.lookahead }
        set { reader.lookahead = newValue }
    }

    /// The UTF-16 offset in the text of what is being heard now (approximate within a sentence).
    public var characterPosition: Int { reader.characterPosition }

    /// The sentence being heard now.
    public var sentenceIndex: Int { reader.sentenceIndex }

    /// The last `read` returned less than asked because the next sentence was still being rendered.
    public var isBuffering: Bool { reader.isWaiting }

    /// Everything has been read.
    public var isFinished: Bool { reader.isFinished }

    /// The most recent rendering failure, if any. A sentence that fails is skipped.
    public var lastError: Error? { reader.lastError }

    /// Splits `text` into sentences and starts rendering the first ones. `voiceRate` is the system rate (see
    /// `SpeechRate`); `speed` multiplies it.
    public init(_ text: String, voice: SpeechVoice, voiceRate: Float = SpeechRate.normal) throws {
        self.voice = voice
        rate = voiceRate
        let first = try AppleSentenceVoice(voice: voice, rate: voiceRate)
        reader = try VoicedText(text, voice: first,
                                options: VoicedText.Options(sampleRate: first.sampleRate, lookahead: 30))
    }

    deinit {
        reader.close()
    }

    /// Changes the speechwarp stream's other settings (nonlinear amount, heard pause, floor blend, rhythm ...)
    /// safely. Do not keep the stream.
    public func configure(_ body: (SpeechwarpStream) -> Void) {
        reader.configure(body)
    }

    /// Returns up to `maxFrames` mono samples to play next. Never waits.
    public func read(maxFrames: Int) -> [Float] {
        reader.read(maxFrames: maxFrames)
    }

    /// Continues from the start of the sentence containing UTF-16 offset `offset`.
    public func seek(toCharacter offset: Int) {
        reader.seek(toCharacter: offset)
    }

    /// Sentences by the system's tokenizer; any longer than 400 characters are cut at the last comma, semicolon
    /// or space before that, so that rendering never stalls on one enormous sentence.
    static func split(_ text: String) -> [Sentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [Sentence] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var piece = range
            while text.distance(from: piece.lowerBound, to: piece.upperBound) > 400 {
                let limit = text.index(piece.lowerBound, offsetBy: 400)
                let window = text[piece.lowerBound..<limit]
                let cut = window.lastIndex(where: { ",;:".contains($0) }).map { text.index(after: $0) }
                    ?? window.lastIndex(where: \.isWhitespace) ?? limit
                result.append(Sentence(range: NSRange(piece.lowerBound..<cut, in: text),
                                       text: String(text[piece.lowerBound..<cut])))
                piece = cut..<piece.upperBound
            }
            let words = text[piece]
            if !words.allSatisfy(\.isWhitespace) {
                result.append(Sentence(range: NSRange(piece, in: text), text: String(words)))
            }
            return true
        }
        return result
    }
}
#endif
