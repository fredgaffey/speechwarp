// The engines a reader can make voices with beyond Apple's own, and the phonemizer neural voices use. The packages
// react-native-speechwarp-voice-espeak and -kokoro each add one; this package finds them by name, so that it does not
// depend on them (eSpeak NG is GPL).
import Foundation

/// A voice that can read, as listVoices reports it.
public struct VoiceInfo {
    public var id: String
    public var name: String
    public var language: String
    public var engine: String
    public var installed: Bool
    public var requiresNetwork: Bool
    public var keepsSpoken: Bool

    public init(id: String, name: String, language: String, engine: String, installed: Bool = true,
                requiresNetwork: Bool = false, keepsSpoken: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.engine = engine
        self.installed = installed
        self.requiresNetwork = requiresNetwork
        self.keepsSpoken = keepsSpoken
    }

    var dictionary: NSDictionary {
        ["id": id, "name": name, "language": language, "engine": engine, "installed": installed,
         "requiresNetwork": requiresNetwork, "keepsSpoken": keepsSpoken]
    }
}

/// An engine whose voices' ids start with `prefix` ("espeak:", "kokoro:").
public protocol VoiceProvider: AnyObject {
    var prefix: String { get }
    /// Called off the main thread.
    func voices() throws -> [VoiceInfo]
    /// Called off the main thread (on the reader's thread for a voice change).
    func makeVoice(id: String) throws -> SentenceVoice
    /// A phonemizer this engine offers to neural voices (eSpeak's), or nil.
    func phonemizer() -> Phonemizer?
}

public extension VoiceProvider {
    func phonemizer() -> Phonemizer? { nil }
}

/// How an engine package is found: a class of this name conforming to it, whose `makeProvider` returns a
/// `VoiceProvider`. (An Objective-C protocol, so that `NSClassFromString` can find it.)
@objc public protocol SpeechwarpVoicePlugin: NSObjectProtocol {
    static func makeProvider() -> AnyObject
}

/// The engines readers can make voices with.
public enum VoiceProviders {
    private static let known = ["SpeechwarpVoiceEspeakPlugin", "SpeechwarpVoiceKokoroPlugin"]
    private static let lock = NSLock()
    private static var providers: [VoiceProvider] = []
    private static var loaded = false
    private static var ownPhonemizer: Phonemizer?

    /// A phonemizer of the app's own for Kokoro, used before any engine's (react-native-speechwarp-voice-espeak's).
    public static var phonemizer: Phonemizer? {
        get { lock.locked { ownPhonemizer } ?? all().lazy.compactMap { $0.phonemizer() }.first }
        set { lock.locked { ownPhonemizer = newValue } }
    }

    /// Adds an engine; one for the same prefix is replaced.
    public static func register(_ provider: VoiceProvider) {
        lock.locked {
            providers.removeAll { $0.prefix == provider.prefix }
            providers.append(provider)
        }
    }

    public static func all() -> [VoiceProvider] {
        lock.locked {
            if !loaded {
                loaded = true
                for name in known {
                    guard let plugin = NSClassFromString(name) as? SpeechwarpVoicePlugin.Type,
                          let provider = plugin.makeProvider() as? VoiceProvider,
                          !providers.contains(where: { $0.prefix == provider.prefix }) else { continue }
                    providers.append(provider)
                }
            }
            return providers
        }
    }

    /// The engine for a voice id, or nil.
    public static func find(_ id: String) -> VoiceProvider? {
        all().first { id.hasPrefix($0.prefix) }
    }
}
