import Flutter
import Foundation
import SpeechwarpVoice
import SpeechwarpVoiceKokoro

/// The method channel "speechwarp_voice_kokoro": Kokoro's catalogue of model files, for Dart's `Kokoro`.
public final class SpeechwarpVoiceKokoroPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "speechwarp_voice_kokoro", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SpeechwarpVoiceKokoroPlugin(), channel: channel)
        // speechwarp_voice finds the provider by name; this keeps the linker from leaving it out.
        _ = SpeechwarpVoiceKokoroProvider.self
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "catalogue":
            result([
                "repository": KokoroModels.repository,
                "revision": KokoroModels.revision,
                "defaultModelFile": KokoroModels.defaultModelFile,
                "defaultVoice": KokoroModels.defaultVoice,
                "tokenizer": map(KokoroModels.tokenizer),
                "models": KokoroModels.models.map {
                    ["id": $0.id, "name": $0.name, "description": $0.description, "file": map($0.file)] as [String: Any]
                },
                "voices": KokoroModels.voices.map {
                    ["name": $0.name, "language": $0.language, "isFemale": $0.isFemale, "file": map($0.file)] as [String: Any]
                },
            ] as [String: Any])
        case "missingFiles":
            guard let directory = args["directory"] as? String else {
                return result(FlutterError(code: "kokoro", message: "No directory", details: nil))
            }
            do {
                let files = try KokoroModels.missingFiles(directory, voice: args["voice"] as? String ?? KokoroModels.defaultVoice,
                                                          modelFile: args["modelFile"] as? String ?? KokoroModels.defaultModelFile)
                result(files.map(map))
            } catch {
                result(FlutterError(code: "kokoro", message: String(describing: error), details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

private func map(_ file: KokoroFile) -> [String: Any] {
    ["relativePath": file.relativePath, "sizeBytes": file.sizeBytes, "url": file.url, "sha256": file.sha256]
}

/// Kokoro for speechwarp_voice, which finds this class by its Objective-C name (see its Engines): makes
/// "kokoro:NAME" and "kokoro:NAME/PACE" voices and lists them. Not for use by apps.
@objc(SpeechwarpVoiceKokoroProvider)
public final class SpeechwarpVoiceKokoroProvider: NSObject {
    /// A `SentenceVoice`, or an `NSError`. Options: "kokoroDirectory" and "phonemizer" (both required), "kokoroModelFile".
    @objc(voiceWithID:options:)
    public func voice(id: NSString, options: NSDictionary) -> AnyObject {
        do {
            guard let directory = options["kokoroDirectory"] as? String else { throw ProviderError("No Kokoro model directory") }
            guard let phonemizer = options["phonemizer"] as? Phonemizer else { throw ProviderError("No phonemizer for Kokoro") }
            let parts = (id as String).dropFirst("kokoro:".count).split(separator: "/", omittingEmptySubsequences: false)
            guard let name = parts.first, parts.count <= 2 else { throw ProviderError("\(id) is not a Kokoro voice's id") }
            var speed: Float = 1
            if parts.count == 2 {
                guard let value = Float(parts[1]) else { throw ProviderError("\(id) has no pace that can be read") }
                speed = value
            }
            return try KokoroSentenceVoice(directory: directory, voice: String(name), phonemizer: phonemizer,
                                           modelFile: options["kokoroModelFile"] as? String ?? KokoroModels.defaultModelFile,
                                           speed: speed)
        } catch {
            return error as NSError
        }
    }

    /// Every voice in the catalogue, installed when its files are in "kokoroDirectory".
    @objc(voices:)
    public func voices(_ options: NSDictionary) -> NSArray {
        let directory = options["kokoroDirectory"] as? String
        let modelFile = options["kokoroModelFile"] as? String ?? KokoroModels.defaultModelFile
        return KokoroModels.voices.map { voice -> [String: Any] in
            [
                "id": "kokoro:" + voice.name,
                "name": voice.name,
                "language": voice.language,
                "engine": "kokoro",
                "installed": directory.map { KokoroModels.isInstalled($0, voice: voice.name, modelFile: modelFile) } ?? false,
                "keepsSpoken": true,
                "details": ["isFemale": voice.isFemale],
            ]
        } as NSArray
    }
}

struct ProviderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
