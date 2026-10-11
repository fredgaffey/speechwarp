// eSpeak NG's voices ("espeak:en-gb", or "espeak:en-gb/220/50" at a rate and pitch) and its phonemizer, for
// react-native-speechwarp-voice, which finds the plugin class by name. GPL-3.0-or-later, as eSpeak NG is.
import Foundation
import SpeechwarpVoice

final class EspeakVoiceProvider: VoiceProvider {
    let prefix = "espeak:"

    func voices() throws -> [VoiceInfo] {
        try Espeak.shared.voices().map {
            VoiceInfo(id: prefix + $0.language, name: $0.name, language: $0.language, engine: "espeak")
        }
    }

    func makeVoice(id: String) throws -> SentenceVoice {
        let parts = id.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let language = parts.first, !language.isEmpty, parts.count == 1 || parts.count == 3 else {
            throw EspeakError.noVoice(id)
        }
        if parts.count == 1 { return try EspeakSentenceVoice(language: language) }
        guard let rate = Int(parts[1]), let pitch = Int(parts[2]) else { throw EspeakError.noVoice(id) }
        return try EspeakSentenceVoice(language: language, wordsPerMinute: rate, pitch: pitch)
    }

    func phonemizer() -> Phonemizer? { EspeakPhonemizer() }
}

@objc(SpeechwarpVoiceEspeakPlugin)
final class SpeechwarpVoiceEspeakPlugin: NSObject, SpeechwarpVoicePlugin {
    static func makeProvider() -> AnyObject { EspeakVoiceProvider() }
}

/// What the Objective-C++ TurboModule calls.
@objc(SpeechwarpVoiceEspeakBridge)
public final class SpeechwarpVoiceEspeakBridge: NSObject {
    @objc public func version() -> String { Espeak.shared.version }
    @objc public func variants() -> [String] { Espeak.shared.variants }
    @objc public func phonemize(_ text: String, language: String) throws -> String {
        try Espeak.shared.phonemes(text, language: language)
    }
}

// The Swift package finds eSpeak's data in its resource bundle, Bundle.module; in this pod the data is in the resource
// bundle SpeechwarpVoiceEspeakData (see the podspec).
extension Bundle {
    static let module: Bundle = {
        let here = Bundle(for: SpeechwarpVoiceEspeakPlugin.self)
        return here.url(forResource: "SpeechwarpVoiceEspeakData", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? here
    }()
}
