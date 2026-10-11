// Tests of SpeechwarpVoiceKokoro, the same as Speechwarp.Voice.Kokoro.Tests in C#.
//
// The catalogue and the phoneme fix-ups are tested everywhere. The engine is there only with the package trait
// "Kokoro" (`swift test --traits Kokoro`), and the tests that run the model need a model directory
// (model_fp16.onnx, tokenizer.json, voices/af_heart.bin and voices/bf_emma.bin; see KokoroModels) named by the
// environment variable SPEECHWARP_KOKORO_DIR; they are skipped without one. Those that phonemize real text need the
// espeak-ng command (Homebrew's) on macOS. The one that checks the words also needs SpeechwarpListen and a whisper.cpp
// model named by SPEECHWARP_LISTEN_MODEL.
import Foundation
import SpeechwarpVoice
@testable import SpeechwarpVoiceKokoro
import XCTest

/// Gives back its input trimmed and in lower case, and records what it was asked.
final class StubPhonemizer: Phonemizer, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(text: String, language: String)] = []

    var texts: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.text) }
    var languages: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.language) }

    func phonemize(_ text: String, language: String) throws -> String {
        lock.lock()
        calls.append((text, language))
        lock.unlock()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

final class KokoroCatalogueTests: XCTestCase {
    func testCatalogueListsEveryModelAndVoiceWithHashes() throws {
        XCTAssertEqual(KokoroModels.models.count, 8)
        XCTAssertEqual(KokoroModels.models[0].file.relativePath, KokoroModels.defaultModelFile)
        XCTAssertEqual(KokoroModels.voices.count, 54)
        let files = KokoroModels.models.map(\.file) + KokoroModels.voices.map(\.file) + [KokoroModels.tokenizer]
        let hex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        for file in files {
            XCTAssertEqual(hex.numberOfMatches(in: file.sha256, range: NSRange(location: 0, length: file.sha256.utf16.count)),
                           1, file.relativePath)
            XCTAssertGreaterThan(file.sizeBytes, 0)
            XCTAssertTrue(file.url.hasPrefix("https://huggingface.co/\(KokoroModels.repository)/resolve/\(KokoroModels.revision)/"),
                          file.url)
        }
        XCTAssertEqual(Set(files.map(\.relativePath)).count, files.count)
        XCTAssertTrue(KokoroModels.models[0].file.url.hasSuffix("/onnx/model_fp16.onnx"))
        XCTAssertEqual(KokoroModels.findVoice("af_heart")?.file.relativePath, "voices/af_heart.bin")
        XCTAssertEqual(KokoroModels.findModel("model_q8f16.onnx")?.id, "model_q8f16")
        XCTAssertNil(KokoroModels.findVoice("nobody"))
        // The same pinned revision and hashes as C#.
        XCTAssertEqual(KokoroModels.revision, "1939ad2a8e416c0acfeecc08a694d14ef25f2231")
        XCTAssertEqual(KokoroModels.findVoice("af_heart")?.file.sha256,
                       "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b")
    }

    func testVoiceNamesGiveLanguageAndGender() {
        XCTAssertEqual(KokoroModels.language(of: "af_heart"), "en-us")
        XCTAssertEqual(KokoroModels.language(of: "bm_george"), "en-gb")
        XCTAssertEqual(KokoroModels.language(of: "ff_siwis"), "fr-fr")
        XCTAssertEqual(KokoroModels.language(of: ""), "en-us")
        XCTAssertEqual(KokoroModels.findVoice("bf_emma")?.isFemale, true)
        XCTAssertEqual(KokoroModels.findVoice("am_adam")?.isFemale, false)
        XCTAssertEqual(KokoroModels.findVoice("bf_emma")?.language, "en-gb")
    }

    func testVoicePathRefusesAnythingButAName() throws {
        XCTAssertEqual(try KokoroModels.voicePath("/dir", voice: "af_heart"), "/dir/voices/af_heart.bin")
        XCTAssertThrowsError(try KokoroModels.voicePath("/dir", voice: "../secret")) {
            XCTAssertEqual($0 as? KokoroError, .invalidVoiceName("../secret"))
        }
        XCTAssertThrowsError(try KokoroModels.voicePath("/dir", voice: ""))
        XCTAssertThrowsError(try KokoroModels.voicePath("/dir", voice: "é"))
        XCTAssertFalse(KokoroModels.isInstalled("/dir", voice: "../af_heart"))
    }

    func testIsInstalledChecksEveryFileAndItsSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.path
        func write(_ file: String, _ count: Int64) throws {
            try Data(count: Int(count)).write(to: URL(fileURLWithPath: file))
        }

        XCTAssertFalse(KokoroModels.isInstalled(path, voice: "af_heart", modelFile: "mine.onnx"))
        XCTAssertEqual(try KokoroModels.missingFiles(path, voice: "af_heart").count, 3)
        // A model not in the catalogue may be any size; the catalogue's files must be theirs.
        try write(KokoroModels.modelPath(path, modelFile: "mine.onnx"), 1)
        try write(KokoroModels.tokenizerPath(path), KokoroModels.tokenizer.sizeBytes)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("voices"), withIntermediateDirectories: true)
        try write(KokoroModels.voicePath(path, voice: "af_heart"), 100)
        XCTAssertFalse(KokoroModels.isInstalled(path, voice: "af_heart", modelFile: "mine.onnx"), "a voice cut short")
        try write(KokoroModels.voicePath(path, voice: "af_heart"), KokoroModels.findVoice("af_heart")!.file.sizeBytes)
        XCTAssertTrue(KokoroModels.isInstalled(path, voice: "af_heart", modelFile: "mine.onnx"))
        XCTAssertFalse(KokoroModels.isInstalled(path, voice: "bf_emma", modelFile: "mine.onnx"))
        XCTAssertEqual(try KokoroModels.missingFiles(path, voice: "af_heart").map(\.relativePath), ["model_fp16.onnx"])
        XCTAssertThrowsError(try KokoroModels.missingFiles(path, voice: "af_heart", modelFile: "mine.onnx")) {
            XCTAssertEqual($0 as? KokoroError, .notInCatalogue("mine.onnx"))
        }
    }

    func testPhonemeFixesFollowKokoroJs() {
        XCTAssertEqual(KokoroPhonemes.fix("rɛd rʌn", language: "en-us"), "ɹɛd ɹʌn")
        XCTAssertEqual(KokoroPhonemes.fix("lɔx", language: "en-gb"), "lɔk")
        XCTAssertEqual(KokoroPhonemes.fix("kʲuː", language: "en-us"), "kjuː")
        XCTAssertEqual(KokoroPhonemes.fix("wˈʌnhˈʌndɹɪd", language: "en-us"), "wˈʌn hˈʌndɹɪd")
        XCTAssertEqual(KokoroPhonemes.fix("dˈɔɡ z.", language: "en-us"), "dˈɔɡz.")
        XCTAssertEqual(KokoroPhonemes.fix("nˈaɪnti", language: "en-us"), "nˈaɪndi")
        XCTAssertEqual(KokoroPhonemes.fix("nˈaɪnti", language: "en-gb"), "nˈaɪnti", "only American English")
        XCTAssertEqual(KokoroPhonemes.fix("nˈaɪntiːn", language: "en-us"), "nˈaɪntiːn", "nineteen is left alone")
        XCTAssertEqual(KokoroPhonemes.fix("kəkˈoːɹoʊ", language: "en-us"), "kˈoʊkəɹoʊ")
        XCTAssertEqual(KokoroPhonemes.fix("kəkˈɔːɹoʊ", language: "en-us"), "kˈoʊkəɹoʊ", "eSpeak NG 1.52's Kokoro")
        XCTAssertEqual(KokoroPhonemes.fix("  ðə  ", language: "en-us"), "ðə")
    }

    func testPunctuationIsKeptOutOfThePhonemizer() throws {
        let stub = StubPhonemizer()
        XCTAssertEqual(try KokoroPhonemes.phonemize("Hello, you! How do you do?", language: "en-gb", phonemizer: stub),
                       "hello, you! how do you do?")
        XCTAssertEqual(stub.texts, ["Hello", "you", "How do you do"])
        XCTAssertEqual(Set(stub.languages), ["en-gb"])
    }

    func testTextIsCutBetweenSentences() {
        XCTAssertEqual(KokoroPhonemes.sentences("One. Two!  Three? Four… Five\n\nSix"),
                       ["One.", "Two!", "Three?", "Four…", "Five", "Six"])
        XCTAssertEqual(KokoroPhonemes.sentences("Dr.Who"), ["Dr.Who"])
    }
}

#if Kokoro && canImport(OnnxRuntimeBindings)
#if canImport(SpeechwarpListen)
import SpeechwarpListen
#endif

/// Answers with fixed samples, or nil, and records what it was asked.
final class FakeAccelerator: KokoroAccelerator {
    let answer: [Float]?
    var calls: [(text: String, voice: String, voiceFile: String, language: String, speed: Float)] = []

    init(_ answer: [Float]?) { self.answer = answer }

    func trySpeak(_ text: String, voice: String, voiceFile: String, language: String, speed: Float) throws -> [Float]? {
        calls.append((text, voice, voiceFile, language, speed))
        return answer
    }
}

#if os(macOS)
/// Phonemes from the espeak-ng command (Homebrew's), for the tests, as Speechwarp.Voice.Kokoro.Bench's
/// EspeakCommandPhonemizer in C#. Apps use SpeechwarpVoiceEspeak's EspeakPhonemizer, which links eSpeak NG in.
final class EspeakCommandPhonemizer: Phonemizer {
    let command: String

    init?() {
        guard let found = ["/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng", "/usr/bin/espeak-ng"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        command = found
    }

    func phonemize(_ text: String, language: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["-q", "--ipa", "-b", "1", "-v", language]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A line a clause, as the library's clause-by-clause phonemes are joined.
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
#endif

final class KokoroEngineTests: XCTestCase {
    /// "Hello world, this is Kokoro speaking." in eSpeak NG's American IPA, after kokoro.js's adjustments.
    static let helloPhonemes = "həlˈoʊ wˈɜːld, ðɪs ɪz kˈoʊkəɹoʊ spˈiːkɪŋ."

    /// The model directory, or a skip.
    static func modelDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["SPEECHWARP_KOKORO_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set SPEECHWARP_KOKORO_DIR to a Kokoro model directory to run this test.")
        }
        XCTAssertTrue(KokoroModels.isInstalled(directory, voice: "af_heart"),
                      "SPEECHWARP_KOKORO_DIR has no model with af_heart: \(directory)")
        return directory
    }

    /// The model file to test, model_fp16.onnx unless SPEECHWARP_KOKORO_MODEL names another.
    static var modelFile: String {
        ProcessInfo.processInfo.environment["SPEECHWARP_KOKORO_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? KokoroModels.defaultModelFile
    }

    static func engine(_ phonemizer: Phonemizer = StubPhonemizer()) throws -> KokoroEngine {
        try KokoroEngine(directory: try modelDirectory(), phonemizer: phonemizer, modelFile: modelFile)
    }

    static func espeak() throws -> Phonemizer {
        #if os(macOS)
        if let phonemizer = EspeakCommandPhonemizer() { return phonemizer }
        #endif
        throw XCTSkip("The espeak-ng command is not installed (brew install espeak-ng).")
    }

    static func rms(_ samples: [Float]) -> Double {
        samples.isEmpty ? 0 : (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    private func seconds(_ samples: [Float]) -> Double { Double(samples.count) / Double(KokoroEngine.sampleRate) }

    func testSpeaksKnownPhonemes() throws {
        let engine = try Self.engine()
        let audio = try engine.speakPhonemes(Self.helloPhonemes, voice: "af_heart")
        XCTAssertTrue((1.2..<4.5).contains(seconds(audio)), "\(seconds(audio)) s of audio")
        XCTAssertGreaterThan(Self.rms(audio), 0.02, "speech, not silence")
        XCTAssertLessThanOrEqual(audio.map(abs).max() ?? 0, 1.5, "no wild samples")
        XCTAssertTrue(audio.allSatisfy(\.isFinite))

        let slower = try engine.speakPhonemes(Self.helloPhonemes, voice: "af_heart", speed: 0.7)
        XCTAssertGreaterThan(slower.count, Int(Double(audio.count) * 1.2), "speed 0.7 is slower")
        XCTAssertEqual(try engine.speakPhonemes("", voice: "af_heart"), [])
        XCTAssertEqual(try engine.speak("  ", voice: "af_heart"), [])
    }

    func testMissingVoiceSaysSo() throws {
        let engine = try Self.engine()
        XCTAssertThrowsError(try engine.speakPhonemes(Self.helloPhonemes, voice: "zz_nobody")) {
            guard case .voiceNotFound = $0 as? KokoroError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try engine.speakPhonemes(Self.helloPhonemes, voice: "../af_heart")) {
            XCTAssertEqual($0 as? KokoroError, .invalidVoiceName("../af_heart"))
        }
    }

    func testMissingModelSaysSo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try KokoroEngine(directory: directory.path, phonemizer: StubPhonemizer())) {
            guard case .modelNotFound = $0 as? KokoroError else { return XCTFail("\($0)") }
        }
    }

    func testSpeaksTextThroughThePhonemizer() throws {
        let engine = try Self.engine(try Self.espeak())
        XCTAssertEqual(try engine.phonemize("Hello world, this is Kokoro speaking.", language: "en-us"), Self.helloPhonemes)
        let audio = try engine.speak("Hello world, this is Kokoro speaking.", voice: "af_heart")
        XCTAssertTrue((1.2..<4.5).contains(seconds(audio)), "\(seconds(audio)) s of audio")
        XCTAssertGreaterThan(Self.rms(audio), 0.02)
        let british = try engine.speak("Hello world, this is Kokoro speaking.", voice: "bf_emma")
        XCTAssertGreaterThan(Self.rms(british), 0.02)
    }

    func testLongTextIsSpokenInPieces() throws {
        let engine = try Self.engine()
        // 16 sentences of about 55 tokens, far over 510 in all.
        let sentence = "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ."
        let one = try engine.speak(sentence, voice: "af_heart")
        let many = try engine.speak(Array(repeating: sentence, count: 16).joined(separator: " "), voice: "af_heart")
        let ratio = Double(many.count) / Double(one.count)
        XCTAssertTrue((11.0..<22.0).contains(ratio), "16 sentences gave \(ratio) times one sentence's audio")
        XCTAssertTrue(many.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(Self.rms(many), 0.02)
        // One run of more than 510 tokens with no sentence end is cut, not truncated.
        let run = Array(repeating: "ðə kwˈɪk bɹˈaʊn fˈɑːks", count: 40).joined(separator: ", ")
        let tokens = String(Array(repeating: "ðə kwˈɪk bɹˈaʊn fˈɑːks, ", count: 22).joined().unicodeScalars
            .prefix(KokoroEngine.maxTokens))
        let maxTokensWorth = try engine.speakPhonemes(tokens, voice: "af_heart").count
        XCTAssertGreaterThan(try engine.speakPhonemes(run, voice: "af_heart").count, maxTokensWorth)
    }

    /// The half-precision model on the CPU gives NaN for about one in five of these lengths unless the engine mends
    /// it (see KokoroEngine.runFinite); the other models give none.
    func testNoLengthGivesNaN() throws {
        let engine = try Self.engine()
        let text = Array(("ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ. ɪn nˈaɪntiːn hˈʌndɹɪd twˈɛnti fˈɔːɹ, "
            + "ðə bɹˈɪdʒ wʌz θɹˈiː hˈʌndɹɪd fˈiːt lˈɔŋ. " + Self.helloPhonemes).utf16)
        for length in stride(from: 40, through: text.count, by: 5) {
            let voice = length % 2 == 0 ? "af_heart" : "bf_emma"
            let audio = try engine.speakPhonemes(String(decoding: text[..<length], as: UTF16.self), voice: voice)
            XCTAssertTrue(audio.allSatisfy(\.isFinite), "\(voice), \(length) characters")
            XCTAssertGreaterThan(Self.rms(audio), 0.02, "\(voice), \(length) characters: speech, not silence")
        }
        print("\(engine.modelFile): the model gave NaN \(engine.notFiniteCount) times, mended each time")
    }

    func testOneEngineSpeaksFromSeveralThreads() throws {
        let engine = try Self.engine()
        let alone = try engine.speakPhonemes(Self.helloPhonemes, voice: "af_heart").count
        let lock = NSLock()
        var together = [Int](repeating: -1, count: 4)
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            let count = (try? engine.speakPhonemes(Self.helloPhonemes, voice: i % 2 == 0 ? "af_heart" : "bf_emma"))?.count ?? -1
            lock.lock()
            together[i] = count
            lock.unlock()
        }
        XCTAssertEqual(together[0], alone)
        XCTAssertEqual(together[2], alone)
        XCTAssertTrue(together.allSatisfy { $0 > 0 }, "\(together)")
    }

    func testBenchmarkMeasures() throws {
        let directory = try Self.modelDirectory()
        let result = try KokoroBenchmark.run(directory: directory, phonemizer: StubPhonemizer(),
                                             text: Self.helloPhonemes + "\n\n" + Self.helloPhonemes,
                                             modelFile: Self.modelFile, duration: 30, parallel: 2)
        XCTAssertEqual(result.engines, 2)
        XCTAssertEqual(result.paragraphs, 2)
        XCTAssertGreaterThan(result.audioSeconds, 2)
        XCTAssertGreaterThan(result.timesRealTime, 0)
        print("Kokoro (\(Self.modelFile)) spoke at \(result.timesRealTime)x real time, loaded in \(result.loadSeconds) s")
    }

    // The sentence voice.

    func testSentenceVoiceDescribesItself() throws {
        let voice = try KokoroSentenceVoice(directory: "/nowhere", voice: "bf_emma", phonemizer: StubPhonemizer())
        XCTAssertEqual(voice.id, "kokoro:bf_emma")
        XCTAssertEqual(voice.sampleRate, 24000)
        XCTAssertTrue(voice.keepsSpoken)
        XCTAssertTrue((voice as SentenceVoice).keepsSpoken, "through the protocol too")
        XCTAssertThrowsError(try KokoroSentenceVoice(directory: "/nowhere", voice: "a/b", phonemizer: StubPhonemizer()))
        XCTAssertEqual(try KokoroSentenceVoice(directory: "/nowhere", voice: "af_heart", phonemizer: StubPhonemizer(),
                                               speed: 1.2).id, "kokoro:af_heart/1.2")
        XCTAssertEqual(KokoroSentenceVoice.format(1.25), "1.25")
        XCTAssertEqual(KokoroSentenceVoice.format(0.5), "0.5")
        XCTAssertEqual(KokoroSentenceVoice.format(2), "2")
        XCTAssertEqual(KokoroSentenceVoice.format(1.23456), "1.235")
        // Rounded as C# rounds "0.###": a half up, from the float's first 7 digits.
        XCTAssertEqual(KokoroSentenceVoice.format(1.0625), "1.063")
        XCTAssertEqual(KokoroSentenceVoice.format(1.0005), "1.001")
        XCTAssertEqual(KokoroSentenceVoice.format(0.85), "0.85")
    }

    func testAcceleratorIsTriedFirst() throws {
        let gpu = FakeAccelerator([0.5, -0.5])
        // The model directory does not exist: the engine must never be loaded.
        let voice = try KokoroSentenceVoice(directory: "/nowhere", voice: "bf_emma", phonemizer: StubPhonemizer(),
                                            speed: 1.25, accelerator: gpu)
        XCTAssertEqual(try voice.speak("Good morning."), [0.5, -0.5])
        XCTAssertEqual(gpu.calls.count, 1)
        XCTAssertEqual(gpu.calls[0].text, "Good morning.")
        XCTAssertEqual(gpu.calls[0].voice, "bf_emma")
        XCTAssertEqual(gpu.calls[0].voiceFile, "/nowhere/voices/bf_emma.bin")
        XCTAssertEqual(gpu.calls[0].language, "en-gb")
        XCTAssertEqual(gpu.calls[0].speed, 1.25)
        XCTAssertEqual(try voice.speak(" "), [])
        XCTAssertEqual(voice.id, "kokoro:bf_emma/1.25")
    }

    func testDeclinedSentencesGoToTheCpu() throws {
        let gpu = FakeAccelerator(nil)
        let engine = try Self.engine()
        let voice = try KokoroSentenceVoice(engine: engine, voice: "af_heart", accelerator: gpu)
        let audio = try voice.speak(Self.helloPhonemes)
        XCTAssertEqual(gpu.calls.count, 1)
        XCTAssertGreaterThan(Self.rms(audio), 0.02)
        voice.close()
        XCTAssertFalse(try engine.speakPhonemes(Self.helloPhonemes, voice: "af_heart").isEmpty,
                       "a shared engine outlives the voice")
    }

    func testOwnEngineIsLoadedWhenNeededAndFreed() throws {
        let voice = try KokoroSentenceVoice(directory: try Self.modelDirectory(), voice: "af_heart",
                                            phonemizer: StubPhonemizer(), modelFile: Self.modelFile)
        XCTAssertGreaterThan(Self.rms(try voice.speak(Self.helloPhonemes)), 0.02)
        voice.close()
        XCTAssertThrowsError(try voice.speak(Self.helloPhonemes)) { XCTAssertEqual($0 as? KokoroError, .closed) }
    }

    /// The live reader speaks a text in Kokoro's voice, sentence by sentence.
    func testLiveReaderReadsWithKokoro() throws {
        let voice = try KokoroSentenceVoice(directory: try Self.modelDirectory(), voice: "af_heart",
                                            phonemizer: StubPhonemizer(), modelFile: Self.modelFile)
        let book = try VoicedText(Self.helloPhonemes + " " + Self.helloPhonemes, voice: voice)
        defer { book.close() }
        var samples: [Float] = []
        let deadline = Date().addingTimeInterval(60)
        while !book.isFinished && Date() < deadline {
            let chunk = book.read(maxFrames: 4096)
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02) } else { samples += chunk }
        }
        XCTAssertTrue(book.isFinished, "the reader finished within a minute")
        XCTAssertGreaterThan(Double(samples.count) / Double(book.sampleRate), 1.5)
        XCTAssertGreaterThan(Self.rms(samples), 0.02)
    }

    #if canImport(SpeechwarpListen)
    /// Whisper hears the words.
    @available(macOS 13.3, iOS 16.4, *)
    func testWhisperHearsWhatKokoroSaid() async throws {
        let directory = try Self.modelDirectory()
        let phonemizer = try Self.espeak()
        guard let whisperModel = ProcessInfo.processInfo.environment["SPEECHWARP_LISTEN_MODEL"], !whisperModel.isEmpty else {
            throw XCTSkip("Set SPEECHWARP_LISTEN_MODEL to a whisper.cpp model to run this test.")
        }
        let voice = try KokoroSentenceVoice(directory: directory, voice: "af_heart", phonemizer: phonemizer,
                                            modelFile: Self.modelFile)
        let audio = try voice.speak("The quick brown fox jumps over the lazy dog. In 1924, the bridge was three hundred feet long.")
        let whisper = try WhisperTranscriber(modelPath: whisperModel)
        try await whisper.prepare(progress: nil)
        let text = try await whisper.transcribe(audio, sampleRate: voice.sampleRate, options: .init()).text
        let heard = String(text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
        for word in ["quick", "brown", "fox", "lazy", "dog", "bridge", "feet", "long"] {
            XCTAssertTrue(heard.contains(word), "Whisper heard: \(heard)")
        }
    }
    #endif
}
#endif
