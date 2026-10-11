// Kokoro-82M on ONNX Runtime's CPU, through Microsoft's Swift package (onnxruntime-swift-package-manager). The same as
// Speechwarp.Voice.Kokoro's KokoroEngine in C#. ONNX Runtime is fetched only by a package that turns on this package's
// trait "Kokoro"; without it this file is left out and `KokoroEngine` says how to turn it on.
#if Kokoro && canImport(OnnxRuntimeBindings)
import Foundation
import OnnxRuntimeBindings
import SpeechwarpVoice

/// Kokoro-82M, a small neural text-to-speech model (af_heart and the other voices), run with ONNX Runtime on the
/// CPU. Text goes to phonemes (IPA) through a `Phonemizer`, as kokoro.js and kokoro-onnx do with eSpeak NG, then
/// through the model with the voice's style. 24 kHz mono.
///
/// The model directory holds the model (model_fp16.onnx or another of `KokoroModels.models`), tokenizer.json and
/// voices/NAME.bin; `KokoroModels` lists where to download them.
///
/// Punctuation is kept out of the phonemizer and given to the model as it is, for its phrasing; the phonemes are then
/// adjusted as kokoro.js does. Text longer than the model's 510 tokens is spoken in pieces, split between sentences
/// where it can be.
///
/// Thread safety: `speak` and `speakPhonemes` may be called from several threads at once (ONNX Runtime runs a
/// session concurrently, and the voices are shared under a lock) provided the phonemizer is itself safe to call from
/// several threads. Loading the model takes a second or more and about the model's size in memory, so share one
/// engine between voices rather than making one per voice. `close` must not overlap a call.
public final class KokoroEngine: @unchecked Sendable {
    /// Frames a second of what the engine returns: 24,000. Mono.
    public static let sampleRate = 24000

    /// The most phoneme tokens the model takes at once.
    public static let maxTokens = 510

    private static let styleSize = 256

    /// One ONNX Runtime environment for the process, as ONNX Runtime recommends.
    private static let environment: Result<ORTEnv, Error> = Result { try ORTEnv(loggingLevel: .warning) }

    /// The model directory given to the initialiser.
    public let directory: String
    /// The model's file name in the directory.
    public let modelFile: String
    /// CPU threads for one sentence; 0 for one a core.
    public let threads: Int

    private let phonemizer: Phonemizer
    private let vocabulary: [Unicode.Scalar: Int64]
    private let space: Int64
    private let breaks: Set<Int64>
    private let outputName: String
    private let lock = NSLock()
    private var session: ORTSession?
    private var voices: [String: [Float]] = [:]
    private var notFinite = 0

    /// Loads the model in `directory`.
    ///
    /// - Parameters:
    ///   - directory: Holds the model, tokenizer.json and voices/NAME.bin (see `KokoroModels`).
    ///   - phonemizer: Turns runs of words into IPA, such as SpeechwarpVoiceEspeak's `EspeakPhonemizer`.
    ///   - modelFile: The model's file name in the directory; `KokoroModels.defaultModelFile` (model_fp16.onnx) by
    ///     default.
    ///   - threads: CPU threads for one sentence; 0 (the default) for one a core.
    /// - Throws: `KokoroError.modelNotFound` or `.tokenizerNotFound` when a file is missing, `.invalidTokenizer`,
    ///   `.invalidThreads`, or `.onnxRuntime` when ONNX Runtime cannot load the model.
    public init(directory: String, phonemizer: Phonemizer, modelFile: String = KokoroModels.defaultModelFile,
                threads: Int = 0) throws {
        guard threads >= 0 else { throw KokoroError.invalidThreads(threads) }
        self.directory = directory
        self.modelFile = modelFile
        self.threads = threads
        self.phonemizer = phonemizer

        let modelPath = KokoroModels.modelPath(directory, modelFile: modelFile)
        let tokenizerPath = KokoroModels.tokenizerPath(directory)
        guard FileManager.default.fileExists(atPath: modelPath) else { throw KokoroError.modelNotFound(modelPath) }
        guard FileManager.default.fileExists(atPath: tokenizerPath) else {
            throw KokoroError.tokenizerNotFound(tokenizerPath)
        }
        let vocabulary = try Self.readVocabulary(tokenizerPath)
        self.vocabulary = vocabulary
        space = vocabulary[" "] ?? -1
        breaks = Set(".,;:!?—…".unicodeScalars.compactMap { vocabulary[$0] })

        do {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(threads > 0 ? threads : ProcessInfo.processInfo.activeProcessorCount))
            try options.setGraphOptimizationLevel(.all)
            let session = try ORTSession(env: try Self.environment.get(), modelPath: modelPath, sessionOptions: options)
            guard let output = try session.outputNames().first else {
                throw KokoroError.onnxRuntime("The model has no output.")
            }
            self.session = session
            outputName = output
        } catch let error as KokoroError {
            throw error
        } catch {
            throw KokoroError.onnxRuntime(error.localizedDescription)
        }
    }

    /// How many times the model has answered with NaN and been run again (for tests and diagnostics).
    var notFiniteCount: Int { lock.locked { notFinite } }

    /// Speaks `text` (a sentence or a few) in `voice`, such as "af_heart", at `speed` (1 is the voice's own pace;
    /// about 0.5 to 2 work).
    ///
    /// - Returns: Mono samples at `sampleRate`, -1 to 1; empty when there is nothing to say.
    /// - Throws: `KokoroError.voiceNotFound` when the voice's file is not in the voices folder, `.closed`, or what the
    ///   phonemizer throws.
    public func speak(_ text: String, voice: String, speed: Float = 1) throws -> [Float] {
        try checkOpen()
        let style = try self.style(voice)
        let language = KokoroModels.language(of: voice)
        var tokens: [Int64] = []
        var audio: [Float] = []
        for sentence in KokoroPhonemes.sentences(text) {
            let trimmed = KokoroPhonemes.trim(sentence)
            if trimmed.isEmpty { continue }
            let ids = tokenize(try phonemize(trimmed, language: language))
            if ids.isEmpty { continue }
            // Sentences go to the model together, for their phrasing, while they fit.
            if !tokens.isEmpty && tokens.count + 1 + ids.count > Self.maxTokens {
                try runAll(tokens, style: style, speed: speed, into: &audio)
                tokens.removeAll()
            }
            if !tokens.isEmpty && space >= 0 { tokens.append(space) }
            tokens += ids
        }
        try runAll(tokens, style: style, speed: speed, into: &audio)
        return audio
    }

    /// Speaks `phonemes`, IPA as `phonemize` returns it, in `voice`, for callers that make phonemes some other way.
    /// Characters the model does not know are left out.
    ///
    /// - Returns: Mono samples at `sampleRate`, -1 to 1; empty when there is nothing to say.
    public func speakPhonemes(_ phonemes: String, voice: String, speed: Float = 1) throws -> [Float] {
        try checkOpen()
        let style = try self.style(voice)
        var audio: [Float] = []
        try runAll(tokenize(phonemes), style: style, speed: speed, into: &audio)
        return audio
    }

    /// The phonemes the model is given for `text`: the phonemizer's IPA between the punctuation, which is kept,
    /// adjusted as kokoro.js does.
    ///
    /// - Parameter language: "en-us", "en-gb" or another of `KokoroModels.language(of:)`'s answers.
    public func phonemize(_ text: String, language: String) throws -> String {
        try KokoroPhonemes.phonemize(text, language: language, phonemizer: phonemizer)
    }

    /// Frees the model. The engine cannot be used afterwards: every call throws `KokoroError.closed`. It is also freed
    /// when the engine is released.
    public func close() {
        lock.locked { session = nil }
    }

    private func checkOpen() throws {
        if lock.locked({ session == nil }) { throw KokoroError.closed }
    }

    /// The model's token ids for `phonemes`; characters it does not know are left out.
    func tokenize(_ phonemes: String) -> [Int64] {
        phonemes.unicodeScalars.compactMap { vocabulary[$0] }
    }

    /// Runs the model on `tokens`, in pieces of at most `maxTokens`.
    private func runAll(_ tokens: [Int64], style: [Float], speed: Float, into audio: inout [Float]) throws {
        var start = 0
        while start < tokens.count {
            let count = pieceLength(tokens, from: start)
            audio += try runFinite(Array(tokens[start..<start + count]), style: style, speed: speed, depth: 0)
            start += count
        }
    }

    /// Runs the model, and when its answer is not all numbers runs it again differently: the half-precision model
    /// (model_fp16) on ONNX Runtime's CPU gives NaN for the whole of some inputs (about one in five of the lengths
    /// tried), depending on the exact tokens; the full-precision and q8f16 models did not. A space added at the end
    /// mends most; the rest are split in two near the middle, at punctuation or a space. Whatever still fails is
    /// returned as silence, so callers never get NaN.
    private func runFinite(_ ids: [Int64], style: [Float], speed: Float, depth: Int) throws -> [Float] {
        var audio = try run(ids, style: style, speed: speed)
        if Self.isFinite(audio) { return audio }
        lock.locked { notFinite += 1 }
        if space >= 0 && ids.last != space && ids.count < Self.maxTokens {
            audio = try run(ids + [space], style: style, speed: speed)
            if Self.isFinite(audio) { return audio }
        }
        let middle = depth < 4 ? splitPoint(ids) : -1
        if middle > 0 {
            let first = try runFinite(Array(ids[..<middle]), style: style, speed: speed, depth: depth + 1)
            let second = try runFinite(Array(ids[middle...]), style: style, speed: speed, depth: depth + 1)
            return first + second
        }
        for i in audio.indices where !audio[i].isFinite { audio[i] = 0 }
        return audio
    }

    private static func isFinite(_ audio: [Float]) -> Bool {
        audio.allSatisfy { $0.isFinite }
    }

    /// Where to cut `ids` in two: after the punctuation nearest the middle, or failing that the space nearest it; -1
    /// when there is neither, or the run is too short to be worth cutting.
    private func splitPoint(_ ids: [Int64]) -> Int {
        if ids.count < 8 { return -1 }
        let half = ids.count / 2
        var best = -1, bestSpace = -1
        for i in 2..<(ids.count - 2) {
            let distance = abs(i - half)
            if breaks.contains(ids[i]) && (best < 0 || distance < abs(best - half)) { best = i }
            if ids[i] == space && (bestSpace < 0 || distance < abs(bestSpace - half)) { bestSpace = i }
        }
        let cut = best >= 0 ? best : bestSpace
        return cut >= 0 ? cut + 1 : -1
    }

    /// How many tokens from `start` go to the model together: all that are left if they fit, or else up to the last
    /// punctuation, or failing that the last space, within `maxTokens`.
    private func pieceLength(_ tokens: [Int64], from start: Int) -> Int {
        let left = tokens.count - start
        if left <= Self.maxTokens { return left }
        var lastPunctuation = -1, lastSpace = -1
        var i = start + Self.maxTokens - 1
        while i > start {
            if lastPunctuation < 0 && breaks.contains(tokens[i]) { lastPunctuation = i }
            if lastSpace < 0 && tokens[i] == space { lastSpace = i }
            if lastPunctuation >= 0 { break }
            i -= 1
        }
        let end = lastPunctuation >= 0 ? lastPunctuation : lastSpace
        return end > start ? end - start + 1 : Self.maxTokens
    }

    private func run(_ ids: [Int64], style: [Float], speed: Float) throws -> [Float] {
        guard let session = lock.locked({ session }) else { throw KokoroError.closed }
        if ids.isEmpty { return [] }
        // The model expects the ids between two padding tokens (0); the style row is chosen by the length.
        var input = [Int64](repeating: 0, count: ids.count + 2)
        input.replaceSubrange(1...ids.count, with: ids)
        let rows = style.count / Self.styleSize
        let row = min(ids.count, rows - 1)
        let styleRow = Array(style[(row * Self.styleSize)..<((row + 1) * Self.styleSize)])
        do {
            let inputs: [String: ORTValue] = [
                "input_ids": try ORTValue(tensorData: Self.data(input), elementType: .int64,
                                          shape: [1, NSNumber(value: input.count)]),
                "style": try ORTValue(tensorData: Self.data(styleRow), elementType: .float,
                                      shape: [1, NSNumber(value: Self.styleSize)]),
                "speed": try ORTValue(tensorData: Self.data([speed]), elementType: .float, shape: [1]),
            ]
            let outputs = try session.run(withInputs: inputs, outputNames: [outputName], runOptions: nil)
            guard let output = outputs[outputName] else { throw KokoroError.onnxRuntime("The model gave no audio.") }
            let data = try output.tensorData() as Data
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } catch let error as KokoroError {
            throw error
        } catch {
            throw KokoroError.onnxRuntime(error.localizedDescription)
        }
    }

    private static func data<T>(_ values: [T]) -> NSMutableData {
        values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
    }

    /// The style vectors of `name`, read from voices/NAME.bin the first time.
    private func style(_ name: String) throws -> [Float] {
        let path = try KokoroModels.voicePath(directory, voice: name)
        if let style = lock.locked({ voices[name] }) { return style }
        guard let data = FileManager.default.contents(atPath: path) else { throw KokoroError.voiceNotFound(path) }
        let rowBytes = Self.styleSize * MemoryLayout<Float>.size
        guard data.count >= rowBytes, data.count % rowBytes == 0 else { throw KokoroError.invalidVoiceFile(path) }
        let style = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.locked { voices[name] = style }
        return style
    }

    private static func readVocabulary(_ path: String) throws -> [Unicode.Scalar: Int64] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Any] else {
            throw KokoroError.invalidTokenizer(path)
        }
        var vocabulary: [Unicode.Scalar: Int64] = [:]
        for (key, value) in vocab {
            let scalars = key.unicodeScalars
            guard scalars.count == 1, let id = (value as? NSNumber)?.int64Value else { continue }
            vocabulary[scalars.first!] = id
        }
        return vocabulary
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
/// Kokoro on ONNX Runtime needs this package's trait "Kokoro", which also fetches ONNX Runtime. Turn it on where the
/// package is added: `.package(url: "https://github.com/fredgaffey/speechwarp", from: "…", traits: ["Kokoro"])`, or
/// in Xcode's Package Dependencies list. On iOS and macOS only.
@available(*, unavailable, message: "Turn on the speechwarp package's trait \"Kokoro\" (iOS and macOS) to get KokoroEngine")
public final class KokoroEngine {}
#endif
