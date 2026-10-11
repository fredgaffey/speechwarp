import Foundation
import SpeechwarpVoice

/// A failure to make a voice, with the code Dart's PlatformException carries.
struct EngineError: LocalizedError {
    /// "voice" for an id whose engine is not in the app, "kokoro" when Kokoro has no model directory or phonemizer.
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// The voice engines: Apple's (always), and Kokoro and eSpeak NG when their Flutter packages
/// (speechwarp_voice_kokoro, speechwarp_voice_espeak) are in the app.
///
/// Each of those packages carries the engine's Swift library and one "provider" class, found here by its
/// Objective-C name, so that this package neither depends on them nor links them (eSpeak NG is GPL-3.0-or-later;
/// Kokoro brings ONNX Runtime). A provider is an `NSObject` with a plain `init()` and these Objective-C methods, which
/// take the options built by the plugin ("kokoroDirectory", "kokoroModelFile", "phonemizer"):
///
/// - `voiceWithID:options:` returns a `SentenceVoice` for one of its ids, or an `NSError`;
/// - `voices:` returns an array of dictionaries, as Dart's `VoiceInfo.fromMap` reads them;
/// - eSpeak's also has `phonemizer`, which returns a `Phonemizer`: Kokoro's unless the app sets
///   `SpeechwarpVoicePlugin.phonemizer`.
final class Engines {
    private lazy var kokoro: NSObject? = Self.load("SpeechwarpVoiceKokoroProvider")
    private lazy var espeak: NSObject? = Self.load("SpeechwarpVoiceEspeakProvider")
    private let lock = NSLock()

    private static func load(_ name: String) -> NSObject? {
        (NSClassFromString(name) as? NSObject.Type)?.init()
    }

    private var kokoroProvider: NSObject? { lock.lock(); defer { lock.unlock() }; return kokoro }
    private var espeakProvider: NSObject? { lock.lock(); defer { lock.unlock() }; return espeak }

    private static func voice(_ provider: NSObject, _ id: String, _ options: [String: Any]) throws -> SentenceVoice {
        let made = provider.perform(NSSelectorFromString("voiceWithID:options:"), with: id as NSString,
                                    with: options as NSDictionary)?.takeUnretainedValue()
        if let voice = made as? SentenceVoice { return voice }
        if let error = made as? Error { throw error }
        throw EngineError(code: "voice", message: "The engine made no voice for \(id)")
    }

    /// Makes voices by id: for the reader's first voice, and for `setVoice` on the reader's thread.
    func factory(_ options: [String: Any]) -> (String) throws -> SentenceVoice {
        { [self] id in
            if id.hasPrefix(AppleSentenceVoice.idPrefix) {
                return try AppleSentenceVoice(identifier: id)
            }
            if id.hasPrefix("kokoro:") {
                guard let kokoro = kokoroProvider else {
                    throw EngineError(code: "voice", message: "\(id) is a Kokoro voice: add the speechwarp_voice_kokoro package to the app")
                }
                guard options["kokoroDirectory"] is String else {
                    throw EngineError(code: "kokoro", message: "Kokoro needs ReaderOptions.kokoroDirectory, the folder of its model files")
                }
                var all = options
                if all["phonemizer"] == nil, let espeak = espeakProvider {
                    all["phonemizer"] = espeak.perform(NSSelectorFromString("phonemizer"))?.takeUnretainedValue()
                }
                guard all["phonemizer"] is Phonemizer else {
                    throw EngineError(code: "kokoro", message: "Kokoro needs a phonemizer: add speechwarp_voice_espeak "
                        + "(GPL-3.0-or-later), or set SpeechwarpVoicePlugin.phonemizer from the app's Swift")
                }
                return try Self.voice(kokoro, id, all)
            }
            if id.hasPrefix("espeak:") {
                guard let espeak = espeakProvider else {
                    throw EngineError(code: "voice", message: "\(id) is an eSpeak NG voice: add the speechwarp_voice_espeak package to the app")
                }
                return try Self.voice(espeak, id, options)
            }
            throw EngineError(code: "voice", message: "No engine for the voice \(id)")
        }
    }

    /// Every voice: Apple's, then Kokoro's and eSpeak's when they are there.
    func voices(_ options: [String: Any]) -> [[String: Any]] {
        var list: [[String: Any]] = SpeechVoice.all.map { voice in
            [
                "id": AppleSentenceVoice.idPrefix + voice.identifier,
                "name": voice.name,
                "language": voice.language,
                "engine": "apple",
                "installed": true,
                "keepsSpoken": false,
                "details": ["isEloquence": voice.isEloquence],
            ]
        }
        for provider in [kokoroProvider, espeakProvider].compactMap({ $0 }) {
            let more = provider.perform(NSSelectorFromString("voices:"), with: options as NSDictionary)?.takeUnretainedValue()
            list += more as? [[String: Any]] ?? []
        }
        return list
    }
}
