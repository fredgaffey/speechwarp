// Kokoro's voices ("kokoro:af_heart", or "kokoro:af_heart/1.2" at another pace) for react-native-speechwarp-voice,
// which finds the plugin class by name, and the catalogue of its files for JavaScript.
import Foundation
import SpeechwarpVoice

/// Where Kokoro's files are and which model it loads; set from JavaScript.
enum KokoroSettings {
    private static let lock = NSLock()
    private static var chosenDirectory: String?
    private static var chosenModel = KokoroModels.defaultModelFile

    static var directory: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let chosenDirectory { return chosenDirectory }
            // Application Support, which iOS does not clear (unlike Caches); kept out of iCloud backups.
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("speechwarp-kokoro").path
        }
        set { lock.lock(); chosenDirectory = newValue; lock.unlock() }
    }

    static var modelFile: String {
        get { lock.lock(); defer { lock.unlock() }; return chosenModel }
        set { lock.lock(); chosenModel = newValue; lock.unlock() }
    }
}

final class KokoroVoiceProvider: VoiceProvider {
    let prefix = KokoroSentenceVoiceID.prefix

    func voices() throws -> [VoiceInfo] {
        let directory = KokoroSettings.directory, model = KokoroSettings.modelFile
        return KokoroModels.voices.map {
            VoiceInfo(id: prefix + $0.name, name: $0.name, language: $0.language, engine: "kokoro",
                      installed: Self.engineIncluded && KokoroModels.isInstalled(directory, voice: $0.name, modelFile: model),
                      keepsSpoken: true)
        }
    }

    func makeVoice(id: String) throws -> SentenceVoice {
        let parts = id.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, !name.isEmpty, parts.count <= 2 else { throw Self.error("\(id) is not a Kokoro voice's id") }
        let speed = parts.count == 2 ? Float(parts[1]) : 1
        guard let speed else { throw Self.error("\(id): the pace is not a number") }
        #if Kokoro && canImport(onnxruntime_objc)
        guard let phonemizer = VoiceProviders.phonemizer else {
            throw Self.error("Kokoro needs a phonemizer: add react-native-speechwarp-voice-espeak (GPL-3.0-or-later), "
                + "or set VoiceProviders.phonemizer to one of your own")
        }
        let directory = KokoroSettings.directory, model = KokoroSettings.modelFile
        let missing = try KokoroModels.missingFiles(directory, voice: name, modelFile: model)
        guard missing.isEmpty else {
            throw Self.error("Kokoro's files are not all in \(directory): missing "
                + missing.map(\.relativePath).joined(separator: ", "))
        }
        return try KokoroSentenceVoice(directory: directory, voice: name, phonemizer: phonemizer, modelFile: model, speed: speed)
        #else
        throw Self.error("This app was built without Kokoro's engine: set SPEECHWARP_KOKORO=1 for pod install")
        #endif
    }

    static var engineIncluded: Bool {
        #if Kokoro && canImport(onnxruntime_objc)
        return true
        #else
        return false
        #endif
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "speechwarp-voice-kokoro", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum KokoroSentenceVoiceID {
    static let prefix = "kokoro:"
}

@objc(SpeechwarpVoiceKokoroPlugin)
final class SpeechwarpVoiceKokoroPlugin: NSObject, SpeechwarpVoicePlugin {
    static func makeProvider() -> AnyObject { KokoroVoiceProvider() }
}

/// What the Objective-C++ TurboModule calls.
@objc(SpeechwarpVoiceKokoroBridge)
public final class SpeechwarpVoiceKokoroBridge: NSObject {
    private static func file(_ file: KokoroFile) -> NSDictionary {
        ["path": file.relativePath, "size": file.sizeBytes, "url": file.url, "sha256": file.sha256]
    }

    @objc public func catalogue() -> NSDictionary {
        [
            "repository": KokoroModels.repository,
            "revision": KokoroModels.revision,
            "defaultModelFile": KokoroModels.defaultModelFile,
            "defaultVoice": KokoroModels.defaultVoice,
            "tokenizer": Self.file(KokoroModels.tokenizer),
            "models": KokoroModels.models.map {
                ["id": $0.id, "name": $0.name, "description": $0.description, "file": Self.file($0.file)] as NSDictionary
            },
            "voices": KokoroModels.voices.map {
                ["name": $0.name, "language": $0.language, "female": $0.isFemale, "file": Self.file($0.file)] as NSDictionary
            },
        ]
    }

    @objc public func directory() -> String { KokoroSettings.directory }
    @objc public func setDirectory(_ path: String) { KokoroSettings.directory = path }
    @objc public func modelFile() -> String { KokoroSettings.modelFile }
    @objc public func setModelFile(_ name: String) -> Bool {
        guard KokoroModels.findModel(name) != nil else { return false }
        KokoroSettings.modelFile = name
        return true
    }

    @objc public func missingFiles(_ voice: String) -> NSArray {
        let files = (try? KokoroModels.missingFiles(KokoroSettings.directory, voice: voice, modelFile: KokoroSettings.modelFile)) ?? []
        return files.map(Self.file) as NSArray
    }

    @objc public func isInstalled(_ voice: String) -> Bool {
        KokoroModels.isInstalled(KokoroSettings.directory, voice: voice, modelFile: KokoroSettings.modelFile)
    }

    @objc public func hasPhonemizer() -> Bool { VoiceProviders.phonemizer != nil }
    @objc public func engineIncluded() -> Bool { KokoroVoiceProvider.engineIncluded }
}
