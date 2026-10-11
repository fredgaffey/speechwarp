// The reader works with any engine: most of these tests use a made-up voice (a tone per sentence), which is quick
// and exact; the rest use Apple's voices, which exist only on Apple systems.
#if canImport(AVFoundation) && canImport(NaturalLanguage) && canImport(CryptoKit)
import Foundation
import XCTest
@testable import SpeechwarpVoice

/// A made-up engine: a sine tone of its own loudness, `framesPerCharacter` frames for each UTF-16 character.
private final class ToneVoice: SentenceVoice, @unchecked Sendable {
    let id: String
    let sampleRate: Int
    let keepsSpoken: Bool
    let amplitude: Float
    let delay: TimeInterval
    let framesPerCharacter: Int
    private let lock = NSLock()
    private var said: [String] = []

    init(id: String, sampleRate: Int = 8000, amplitude: Float = 0.5, keepsSpoken: Bool = false,
         delay: TimeInterval = 0, framesPerCharacter: Int? = nil) {
        self.id = id
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.keepsSpoken = keepsSpoken
        self.delay = delay
        self.framesPerCharacter = framesPerCharacter ?? sampleRate / 20
    }

    var spoken: [String] { lock.lock(); defer { lock.unlock() }; return said }

    func speak(_ sentence: String) throws -> [Float] {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        said.append(sentence)
        lock.unlock()
        let count = sentence.utf16.count * framesPerCharacter
        return (0..<count).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / Double(sampleRate))) }
    }
}

private struct Unknown: Error {}

final class VoicedTextTests: XCTestCase {
    private let text = "One is first. Two comes next. Three is here. Four is after that. Five ends it."

    /// Reads until `done` or the deadline, collecting the samples.
    private func readAll(_ reader: VoicedText, chunk: Int = 512, seconds: TimeInterval = 30,
                         until done: ((VoicedText) -> Bool)? = nil) -> [Float] {
        var out: [Float] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !(done?(reader) ?? reader.isFinished) {
            let samples = reader.read(maxFrames: chunk)
            out += samples
            if samples.count < chunk { Thread.sleep(forTimeInterval: 0.005) }
        }
        return out
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float { samples.map(abs).max() ?? 0 }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speechwarp-voice-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsEverySentenceAsSpokenAndFollowsTheTimeline() throws {
        let voice = ToneVoice(id: "tone:a")
        let reader = try VoicedText(text, voice: voice, options: .init(speedUp: false))
        defer { reader.close() }
        XCTAssertFalse(reader.speedsUp)
        XCTAssertEqual(reader.sampleRate, 8000)
        XCTAssertEqual(reader.voiceID, "tone:a")
        XCTAssertEqual(reader.duration, Double(text.utf16.count) / 17, accuracy: 1e-9)

        var out: [Float] = []
        var positions: [Int] = []
        let deadline = Date().addingTimeInterval(30)
        while !reader.isFinished && Date() < deadline {
            let samples = reader.read(maxFrames: 300)
            out += samples
            positions.append(reader.characterPosition)
            if samples.isEmpty { Thread.sleep(forTimeInterval: 0.005) }
        }
        XCTAssertTrue(reader.isFinished)
        XCTAssertNil(reader.lastError)
        let expected = reader.sentences.reduce(0) { $0 + $1.text.utf16.count * 400 }
        XCTAssertEqual(out.count, expected, "every sentence, nothing more")
        XCTAssertEqual(positions, positions.sorted(), "the position never goes backwards")
        let last = reader.sentences[reader.sentences.count - 1].range
        XCTAssertEqual(positions.last, last.location + last.length)

        // Frame to timeline: the end of the first sentence is the start of the second.
        let first = reader.sentences[0].text.utf16.count * 400
        XCTAssertEqual(reader.character(atFrame: Int64(first)), Double(reader.sentences[1].range.location), accuracy: 1)
        XCTAssertEqual(reader.time(atFrame: Int64(first)), Double(reader.sentences[1].range.location) / 17, accuracy: 0.1)
        XCTAssertEqual(reader.time(atFrame: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(voice.spoken.count, reader.sentences.count, "each sentence spoken once")
    }

    func testChangesVoiceAtTheNextSentenceAndConvertsItsRate() throws {
        let first = ToneVoice(id: "tone:quiet", sampleRate: 8000, amplitude: 0.2)
        let second = ToneVoice(id: "tone:loud", sampleRate: 16000, amplitude: 0.6)
        let reader = try VoicedText(text, voice: first, options: .init(speedUp: false, lookahead: 5))
        defer { reader.close() }
        let sentence0 = reader.sentences[0].text.utf16.count * 400

        // The whole first sentence, and no more.
        var heard: [Float] = []
        let deadline = Date().addingTimeInterval(10)
        while heard.count < sentence0 && Date() < deadline {
            heard += reader.read(maxFrames: sentence0 - heard.count)
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(heard.count, sentence0)
        XCTAssertEqual(reader.sentenceIndex, 1)

        reader.setVoice(second)
        XCTAssertEqual(reader.voiceID, "tone:loud", "the voice asked for, at once")
        heard += readAll(reader)
        XCTAssertTrue(reader.isFinished)
        XCTAssertTrue(reader.voice === second)
        XCTAssertNil(reader.lastError)

        XCTAssertEqual(Double(peak(heard[0..<sentence0])), 0.2, accuracy: 0.01, "the first sentence in the first voice")
        XCTAssertEqual(Double(peak(heard[sentence0...])), 0.6, accuracy: 0.01, "the rest in the second")
        XCTAssertEqual(Double(peak(heard[sentence0..<sentence0 + 400])), 0.6, accuracy: 0.05, "from the very next sentence")
        // The second voice's 16 kHz audio comes out at 8 kHz: the same length as the first voice's would be.
        let expected = reader.sentences.reduce(0) { $0 + $1.text.utf16.count * 400 }
        XCTAssertEqual(Double(heard.count), Double(expected), accuracy: Double(reader.sentences.count))
        XCTAssertFalse(second.spoken.contains(reader.sentences[0].text))
        XCTAssertTrue(second.spoken.contains(reader.sentences[1].text))
    }

    func testMakesVoicesWithAFactoryAndKeepsTheOldOneWhenItFails() throws {
        let made = NSMutableArray()
        let reader = try VoicedText(text, voiceID: "a", factory: { id in
            guard id != "missing" else { throw Unknown() }
            let voice = ToneVoice(id: "tone:" + id)
            made.add(voice)
            return voice
        }, options: .init(speedUp: false))
        defer { reader.close() }
        XCTAssertEqual(reader.voiceID, "a", "the id given to the factory, not the engine's")
        reader.setVoice(id: "missing")
        let deadline = Date().addingTimeInterval(10)
        while reader.lastError == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(reader.lastError is Unknown)
        XCTAssertEqual(reader.voiceID, "a")
        reader.setVoice(id: "b")
        while reader.voice.id != "tone:b" && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(reader.voiceID, "b")
        _ = readAll(reader)
        XCTAssertTrue(reader.isFinished)
        XCTAssertEqual(made.count, 2)
    }

    func testSeeksByCharacterAndByTime() throws {
        let reader = try VoicedText(text, voice: ToneVoice(id: "tone:a"), options: .init(speedUp: false))
        defer { reader.close() }
        let third = reader.sentences[2].range.location

        let frame = reader.seek(toTime: Double(third + 4) / 17)
        XCTAssertEqual(frame, Int64((Double(third) / 17 * 8000).rounded()), "the start of the sentence, on the timeline")
        XCTAssertEqual(reader.sentenceIndex, 2)
        XCTAssertEqual(reader.time(atFrame: frame), Double(third) / 17, accuracy: 1e-6)
        let rest = readAll(reader)
        XCTAssertTrue(reader.isFinished)
        let expected = reader.sentences[2...].reduce(0) { $0 + $1.text.utf16.count * 400 }
        XCTAssertEqual(rest.count, expected)
        // Frames count on from the one the seek returned.
        let fourth = reader.sentences[3].range.location
        XCTAssertEqual(reader.character(atFrame: frame + Int64(reader.sentences[2].text.utf16.count * 400)),
                       Double(fourth), accuracy: 1)

        // Back to the start, by character.
        XCTAssertEqual(reader.seek(toCharacter: 3), 0)
        XCTAssertEqual(reader.characterPosition, 0)
        XCTAssertFalse(reader.isFinished)
        XCTAssertEqual(readAll(reader).count, reader.sentences.reduce(0) { $0 + $1.text.utf16.count * 400 })
    }

    func testSpeedsUpThroughSpeechwarp() throws {
        let voice = ToneVoice(id: "tone:a", sampleRate: 16000, framesPerCharacter: 800)
        let reader = try VoicedText(text, voice: voice)
        defer { reader.close() }
        XCTAssertTrue(reader.speedsUp)
        reader.speed = 2
        reader.configure { $0.nonlinear = 0 }
        let out = readAll(reader)
        XCTAssertTrue(reader.isFinished)
        let spoken = reader.sentences.reduce(0) { $0 + $1.text.utf16.count * 800 }
        XCTAssertEqual(Double(spoken) / Double(out.count), 2, accuracy: 0.3)
        XCTAssertEqual(reader.characterPosition, text.utf16.count - (text.hasSuffix(" ") ? 1 : 0), accuracy: 2)
    }

    func testCacheKeepsBlocksAndGivesThemBack() throws {
        let directory = temporaryDirectory()
        let cache = VoiceCache(text: "some text", voiceID: "kokoro:af_heart", directory: directory)
        XCTAssertEqual(cache.directory.lastPathComponent, "kokoro-af_heart")
        XCTAssertEqual(cache.directory.deletingLastPathComponent().lastPathComponent, VoiceCache.textKey("some text"))
        XCTAssertEqual(VoiceCache.textKey("some text").count, 16)
        XCTAssertFalse(cache.has(0))
        XCTAssertNil(cache.load(0, sampleRate: 24000))

        let tone = { (count: Int) in (0..<count).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / 24000)) } }
        let sentences = [tone(12000), [], tone(30000), tone(7000)]
        try cache.save(3, sentences: sentences, sampleRate: 24000)
        XCTAssertTrue(cache.has(3))
        let loaded = try XCTUnwrap(cache.load(3, sampleRate: 24000))
        XCTAssertEqual(loaded.map(\.count), sentences.map(\.count))
        XCTAssertEqual(Double(AudioSamples.rms(loaded[2])), 0.5 / 2.squareRoot(), accuracy: 0.05, "AAC, but the same tone")
        let converted = try XCTUnwrap(cache.load(3, sampleRate: 12000))
        XCTAssertEqual(converted[0].count, 6000)

        // Unreadable: forgotten, to be spoken again.
        try Data("not audio".utf8).write(to: cache.directory.appendingPathComponent("00003.m4a"))
        XCTAssertNil(cache.load(3, sampleRate: 24000))
        XCTAssertFalse(cache.has(3))
        cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
    }

    /// 45 sentences: one whole block and a short one.
    private var longText: String {
        (1...45).map { "Sentence number \($0) is here." }.joined(separator: " ")
    }

    func testReaderKeepsWhatASlowVoiceSaysAndReadsItBack() throws {
        let directory = temporaryDirectory()
        let options = VoicedText.Options(speedUp: false, keptLookahead: 600, cacheDirectory: directory)
        let slow = ToneVoice(id: "tone:slow", sampleRate: 24000, keepsSpoken: true, delay: 0.005, framesPerCharacter: 120)
        let reader = try VoicedText(longText, voice: slow, options: options)
        XCTAssertEqual(reader.sentences.count, 45)
        let first = readAll(reader, chunk: 4096, seconds: 60)
        XCTAssertTrue(reader.isFinished)
        reader.close()
        let cache = VoiceCache(text: longText, voiceID: "tone:slow", directory: directory)
        let deadline = Date().addingTimeInterval(10)
        while !(cache.has(0) && cache.has(1)) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(cache.has(0) && cache.has(1), "both blocks kept")

        // Another reader in the same voice speaks nothing: it is all on disk.
        let again = ToneVoice(id: "tone:slow", sampleRate: 24000, keepsSpoken: true, framesPerCharacter: 120)
        let second = try VoicedText(longText, voice: again, options: options)
        defer { second.close() }
        let replay = readAll(second, chunk: 4096, seconds: 60)
        XCTAssertTrue(second.isFinished)
        XCTAssertEqual(again.spoken, [])
        XCTAssertEqual(replay.count, first.count, "every sentence its own length")
    }

    func testSpeaksAheadToDiskWhenAllowed() throws {
        let directory = temporaryDirectory()
        let slow = ToneVoice(id: "tone:slow", sampleRate: 24000, keepsSpoken: true, framesPerCharacter: 24)
        let reader = try VoicedText(longText, voice: slow, options: .init(
            speedUp: false, keptLookahead: 1, cacheDirectory: directory, speakAheadToDisk: { true }))
        defer { reader.close() }
        let cache = VoiceCache(text: longText, voiceID: "tone:slow", directory: directory)
        let deadline = Date().addingTimeInterval(20)
        while !(cache.has(0) && cache.has(1)) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(cache.has(0) && cache.has(1), "the whole text kept without being read")
        XCTAssertEqual(Set(slow.spoken).count, 45)
        XCTAssertEqual(slow.spoken.count, 45, "nothing spoken twice")
    }

    // MARK: Apple's voices

    private func eloquence(_ name: String) throws -> SpeechVoice {
        guard let voice = SpeechVoice.eloquence(language: "en-US").first(where: { $0.name == name })
            ?? SpeechVoice.eloquence(language: "en").first(where: { $0.name == name }) else {
            throw XCTSkip("The Eloquence voice \(name) is not installed here")
        }
        return voice
    }

    func testAppleVoiceIsASentenceVoice() throws {
        let reed = try eloquence("Reed")
        let voice = try AppleSentenceVoice(identifier: AppleSentenceVoice.idPrefix + reed.identifier)
        XCTAssertEqual(voice.id, "apple:" + reed.identifier)
        XCTAssertFalse(voice.keepsSpoken)
        XCTAssertGreaterThan(voice.sampleRate, 8000)
        XCTAssertThrowsError(try AppleSentenceVoice(identifier: "no.such.voice"))
        XCTAssertEqual(try voice.speak("  "), [])

        // On the main thread (where this test runs), which is also where the speech arrives.
        XCTAssertTrue(Thread.isMainThread)
        let here = try voice.speak("The quick brown fox.")
        XCTAssertGreaterThan(Double(here.count) / Double(voice.sampleRate), 0.5)

        // And from another thread.
        var there: [Float] = []
        let done = expectation(description: "spoken")
        Thread.detachNewThread {
            there = (try? voice.speak("The quick brown fox.")) ?? []
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(Double(there.count), Double(here.count), accuracy: Double(here.count) * 0.05)
    }

    func testAppleVoicesChangeMidTextAndSeek() async throws {
        let reed = try AppleSentenceVoice(voice: try eloquence("Reed"))
        let flo = try AppleSentenceVoice(voice: try eloquence("Flo"))
        let text = "This is the first sentence. Here is a second one. And a third. A fourth follows it. The fifth ends."
        let reader = try VoicedText(text, voice: reed, options: .init(lookahead: 4))
        defer { reader.close() }
        reader.speed = 2
        var positions: [Int] = []
        var output = 0
        var changed = false
        let deadline = Date().addingTimeInterval(60)
        while !reader.isFinished && Date() < deadline {
            let samples = reader.read(maxFrames: 2048)
            output += samples.count
            positions.append(reader.characterPosition)
            if !changed && reader.sentenceIndex >= 1 {
                reader.setVoice(flo)
                changed = true
            }
            if samples.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(reader.isFinished)
        XCTAssertNil(reader.lastError)
        XCTAssertTrue(reader.voice === flo)
        XCTAssertEqual(reader.voiceID, flo.id)
        XCTAssertEqual(positions, positions.sorted(), "the position never goes backwards")
        XCTAssertGreaterThan(output, reader.sampleRate) // over a second at 2x

        // Back to the third sentence by time.
        let third = reader.sentences[2].range.location
        reader.seek(toTime: reader.secondsPerCharacter * Double(third + 2))
        XCTAssertEqual(reader.sentenceIndex, 2)
        var after = 0
        while !reader.isFinished && Date() < deadline {
            let samples = reader.read(maxFrames: 2048)
            after += samples.count
            XCTAssertGreaterThanOrEqual(reader.characterPosition, third)
            if samples.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(reader.isFinished)
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThan(after, output)
    }
}
#endif
