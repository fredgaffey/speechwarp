#if os(iOS) || os(macOS)
import SpeechwarpVoice
import SpeechwarpVoiceEspeak
import XCTest

final class EspeakTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(Espeak.shared.version, "1.52.0")
    }

    func testSpeaksASentence() throws {
        let voice = try EspeakSentenceVoice(language: "en-gb")
        XCTAssertEqual(voice.id, "espeak:en-gb")
        XCTAssertEqual(voice.sampleRate, 22050)
        let samples = try voice.speak("The quick brown fox jumps over the lazy dog.")
        XCTAssertGreaterThan(samples.count, voice.sampleRate)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.05)
        let faster = try Espeak.shared.speak("The quick brown fox jumps over the lazy dog.", language: "en-gb",
                                             wordsPerMinute: 350)
        XCTAssertLessThan(Double(faster.count), Double(samples.count) * 0.7)
        XCTAssertEqual(try Espeak.shared.speak("  ", language: "en-us"), [])
    }

    func testIdNamesRateAndPitch() throws {
        XCTAssertEqual(try EspeakSentenceVoice(language: "en-us", wordsPerMinute: 220).id, "espeak:en-us/220/50")
    }

    // As eSpeak NG's own command gives it: espeak-ng -q --ipa -v en-us "The quick brown fox".
    func testPhonemes() throws {
        let phonemizer: Phonemizer = EspeakPhonemizer()
        XCTAssertEqual(try phonemizer.phonemize("The quick brown fox", language: "en-us"), "ðə kwˈɪk bɹˈaʊn fˈɑːks")
        XCTAssertEqual(try phonemizer.phonemize("The quick brown fox", language: "en-gb"), "ðə kwˈɪk bɹˈaʊn fˈɒks")
        XCTAssertEqual(try Espeak.shared.phonemes("", language: "en-us"), "")
    }

    func testVoicesAndVariants() throws {
        let voices = try Espeak.shared.voices()
        XCTAssertTrue(voices.contains { $0.identifier == "gmw/en" && $0.language == "en-gb" })
        XCTAssertTrue(voices.contains { $0.language == "en-us" })
        XCTAssertTrue(Espeak.shared.variants.contains("klatt"))
        XCTAssertFalse(try Espeak.shared.speak("Hello.", language: "en-gb+klatt").isEmpty)
    }

    func testUnknownVoiceThrows() throws {
        XCTAssertThrowsError(try Espeak.shared.speak("x", language: "zz-nonsense")) { error in
            XCTAssertEqual(error as? EspeakError, .noVoice("zz-nonsense"))
        }
        XCTAssertFalse(try Espeak.shared.speak("Still works.", language: "en-us").isEmpty)
    }

    func testThreadsTakeTurns() {
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            if i % 2 == 0 {
                XCTAssertFalse(((try? Espeak.shared.speak("Thread \(i)", language: "en-us")) ?? []).isEmpty)
            } else {
                XCTAssertFalse(((try? Espeak.shared.phonemes("Thread \(i)", language: "en-gb")) ?? "").isEmpty)
            }
        }
    }
}
#endif
