// eSpeak NG is licensed under the GPL-3.0-or-later, and so is this package.
import Flutter
import Foundation
#if SPEECHWARP_ESPEAK
import SpeechwarpVoice
import SpeechwarpVoiceEspeak
#endif

/// The method channel "speechwarp_voice_espeak", for Dart's `Espeak`: eSpeak NG's version and phonemes.
public final class SpeechwarpVoiceEspeakPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "speechwarp_voice_espeak", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SpeechwarpVoiceEspeakPlugin(), channel: channel)
        // speechwarp_voice finds the provider by name; this keeps the linker from leaving it out.
        _ = SpeechwarpVoiceEspeakProvider.self
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        DispatchQueue.global(qos: .userInitiated).async {
            let value: Any
            do {
                switch call.method {
                case "version": value = try espeakVersion()
                case "phonemes": value = try espeakPhonemes(args["text"] as? String ?? "", args["language"] as? String ?? "en-us")
                default: value = FlutterMethodNotImplemented
                }
            } catch {
                value = FlutterError(code: "espeak", message: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                                     details: nil)
            }
            DispatchQueue.main.async { result(value) }
        }
    }
}

struct EspeakMissing: LocalizedError {
    var errorDescription: String? {
        "eSpeak NG is not built into this app on iOS: speechwarp_voice_espeak needs a checkout of the speechwarp "
            + "repository in which bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift has been run"
    }
}

#if SPEECHWARP_ESPEAK
private func espeakVersion() throws -> String { Espeak.shared.version.components(separatedBy: " ").first ?? "" }
private func espeakPhonemes(_ text: String, _ language: String) throws -> String { try Espeak.shared.phonemes(text, language: language) }
#else
private func espeakVersion() throws -> String { throw EspeakMissing() }
private func espeakPhonemes(_ text: String, _ language: String) throws -> String { throw EspeakMissing() }
#endif

/// eSpeak NG for speechwarp_voice, which finds this class by its Objective-C name (see its Engines): makes
/// "espeak:LANGUAGE" and "espeak:LANGUAGE/RATE/PITCH" voices, lists them, and gives Kokoro its phonemizer. Not for
/// use by apps.
@objc(SpeechwarpVoiceEspeakProvider)
public final class SpeechwarpVoiceEspeakProvider: NSObject {
    /// A `SentenceVoice`, or an `NSError`.
    @objc(voiceWithID:options:)
    public func voice(id: NSString, options: NSDictionary) -> AnyObject {
        do {
#if SPEECHWARP_ESPEAK
            let parts = (id as String).dropFirst("espeak:".count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 3 else { throw ProviderError("\(id) is not an eSpeak voice's id") }
            if parts.count == 3 {
                guard let rate = Int(parts[1]), let pitch = Int(parts[2]) else {
                    throw ProviderError("\(id) has no rate and pitch that can be read")
                }
                return try EspeakSentenceVoice(language: String(parts[0]), wordsPerMinute: rate, pitch: pitch)
            }
            return try EspeakSentenceVoice(language: String(parts[0]))
#else
            throw EspeakMissing()
#endif
        } catch {
            return error as NSError
        }
    }

    /// eSpeak's voices (none when it is not built in).
    @objc(voices:)
    public func voices(_ options: NSDictionary) -> NSArray {
#if SPEECHWARP_ESPEAK
        let voices = (try? Espeak.shared.voices()) ?? []
        return voices.map { voice -> [String: Any] in
            [
                "id": "espeak:" + voice.language,
                "name": voice.name,
                "language": voice.language,
                "engine": "espeak",
                "installed": true,
                "keepsSpoken": false,
                "details": ["identifier": voice.identifier,
                            "gender": voice.gender == 1 ? "male" : voice.gender == 2 ? "female" : "unknown"],
            ]
        } as NSArray
#else
        return []
#endif
    }

    /// eSpeak's phonemizer, for Kokoro; nil when it is not built in.
    @objc public func phonemizer() -> AnyObject? {
#if SPEECHWARP_ESPEAK
        return EspeakPhonemizer()
#else
        return nil
#endif
    }
}

struct ProviderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
