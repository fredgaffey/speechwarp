// eSpeak NG (GPL-3.0-or-later), linked in from espeak_ng.xcframework, which
// bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh builds. The same as Speechwarp.Voice.Espeak
// in C#. Using this target makes an app subject to the GPL-3.0, unlike the rest of the package (Apache-2.0).
#if os(iOS) || os(macOS)
import CEspeakNG
import Foundation

/// What can go wrong with eSpeak NG.
public enum EspeakError: Error, Equatable {
    /// eSpeak could not start with its data at this path (status as eSpeak gave it).
    case cannotStart(path: String, status: UInt32)
    /// eSpeak has no voice by this name or for this language.
    case noVoice(String)
    /// eSpeak failed to speak (its error code).
    case speakFailed(Int32)
    /// The data path was set after eSpeak had started.
    case alreadyStarted
}

/// A voice in eSpeak's data: one language or accent.
public struct EspeakVoice: Equatable, Sendable {
    /// eSpeak's name for it, such as "English (Great Britain)".
    public let name: String
    /// Its file in the data, such as "gmw/en".
    public let identifier: String
    /// The languages it speaks, the most particular first, such as "en-gb-x-rp", "en-gb" and "en".
    public let languages: [String]
    /// 0 not given, 1 male, 2 female.
    public let gender: Int

    /// The language to ask for this voice by, such as "en-gb".
    public var language: String { languages.first ?? identifier }
}

/// eSpeak NG, linked into the app: speech in its own formant voices, and text to phonemes (IPA) for neural voices
/// such as Kokoro.
///
/// eSpeak keeps its state in globals and is not thread-safe, so every call here takes one lock: calls from several
/// threads take turns. eSpeak starts on the first call that needs it, with its data at `dataPath`.
public final class Espeak: @unchecked Sendable {
    /// The one eSpeak in the process.
    public static let shared = Espeak()

    /// The default speaking rate, in words a minute.
    public static let defaultWordsPerMinute = 175
    /// The default pitch, 0 to 100.
    public static let defaultPitch = 50

    private let lock = NSLock()
    private var started = false
    private var chosenPath: String?
    private var voice: String?

    private init() {}

    /// The folder of eSpeak's data, espeak-ng-data: by default this target's copy (English, in each of eSpeak's
    /// accents, and every voice variant), or else one in the app's main bundle.
    public var dataPath: String {
        lock.lock()
        defer { lock.unlock() }
        return chosenPath ?? Espeak.defaultDataPath
    }

    /// Keeps eSpeak's data at `path` (the folder espeak-ng-data). Call it before anything else that uses eSpeak.
    public func use(dataPath path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if started && path != chosenPath { throw EspeakError.alreadyStarted }
        chosenPath = path
    }

    /// eSpeak NG's version, such as "1.52.0".
    public var version: String { String(cString: espeak_Info(nil)) }

    /// Frames a second of what `speak` returns: 22,050.
    public func sampleRate() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try start()
        return Int(espeak_ng_GetSampleRate())
    }

    /// `text` spoken by eSpeak in the voice `language` ("en-us", "en-gb", "en-gb-x-rp", optionally with a variant,
    /// "en-us+klatt"): mono samples, -1 to 1, at `sampleRate()`, empty for nothing to say. The defaults, 175 words a
    /// minute and pitch 50, are eSpeak's own.
    public func speak(_ text: String, language: String, wordsPerMinute: Int = Espeak.defaultWordsPerMinute,
                      pitch: Int = Espeak.defaultPitch) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        try start()
        try use(language)
        if text.allSatisfy(\.isWhitespace) { return [] }
        espeak_SetParameter(espeakRATE, Int32(clamping: wordsPerMinute), 0)
        espeak_SetParameter(espeakPITCH, Int32(min(max(pitch, 0), 100)), 0)
        synthesized = []
        defer { synthesized = [] }
        let status = text.withCString { start in
            espeak_Synth(start, strlen(start) + 1, 0, POS_CHARACTER, 0, UInt32(espeakCHARS_UTF8), nil, nil)
        }
        if status != EE_OK { throw EspeakError.speakFailed(status.rawValue) }
        return synthesized.map { Float($0) / 32768 }
    }

    /// The phonemes of `text` in IPA, with eSpeak's stress marks, clause by clause (clauses separated by a space),
    /// for the voice `language` ("en-us", "en-gb" and the rest).
    public func phonemes(_ text: String, language: String = "en-us") throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try start()
        try use(language)
        var clauses: [String] = []
        text.withCString { start in
            // eSpeak moves the pointer past each clause it translates, and sets it to null at the end.
            var at: UnsafeRawPointer? = UnsafeRawPointer(start)
            while at != nil {
                guard let clause = espeak_TextToPhonemes(&at, espeakCHARS_UTF8, espeakPHONEMES_IPA) else { continue }
                let phonemes = String(cString: clause)
                if !phonemes.isEmpty { clauses.append(phonemes) }
            }
        }
        return clauses.joined(separator: " ")
    }

    /// The voices in eSpeak's data, one per language and accent, sorted by name.
    public func voices() throws -> [EspeakVoice] {
        lock.lock()
        defer { lock.unlock() }
        try start()
        var voices: [EspeakVoice] = []
        guard let list = espeak_ListVoices(nil) else { return [] }
        var i = 0
        while let voice = list[i] {
            voices.append(Espeak.voice(voice.pointee))
            i += 1
        }
        return voices
    }

    /// The voice variants in eSpeak's data, such as "klatt", "f3" or "m1": added to a voice after a '+'
    /// ("en-us+klatt"), they change its sound.
    public var variants: [String] {
        let folder = (dataPath as NSString).appendingPathComponent("voices/!v")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    // ---- Called with the lock held

    private func start() throws {
        if started { return }
        let path = chosenPath ?? Espeak.defaultDataPath
        // On purpose the espeak_ng_ calls, which report errors: the older espeak_Initialize ends the whole process
        // when it cannot find its data.
        espeak_ng_InitializePath(path)
        var status = espeak_ng_Initialize(nil)
        if status != ENS_OK { throw EspeakError.cannotStart(path: path, status: status.rawValue) }
        status = espeak_ng_InitializeOutput(ENOUTPUT_MODE_SYNCHRONOUS, 0, nil)
        if status != ENS_OK { throw EspeakError.cannotStart(path: path, status: status.rawValue) }
        espeak_SetSynthCallback { wav, count, _ in
            if let wav, count > 0 { synthesized.append(contentsOf: UnsafeBufferPointer(start: wav, count: Int(count))) }
            return 0
        }
        chosenPath = path
        started = true
    }

    private func use(_ language: String) throws {
        if voice == language { return }
        // eSpeak finds a voice by its name or file name ("en-us" is lang/gmw/en-US), but not by a language that names
        // no file: "en-gb" is lang/gmw/en. Then ask it for the voice that suits the language best, as its own
        // command does, and keep any variant ("en-gb+klatt").
        if espeak_ng_SetVoiceByName(language) != ENS_OK {
            guard let identifier = bestVoice(for: language), espeak_ng_SetVoiceByName(identifier) == ENS_OK else {
                throw EspeakError.noVoice(language)
            }
        }
        voice = language
    }

    private func bestVoice(for language: String) -> String? {
        let parts = language.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let variant = parts.count > 1 ? "+" + parts[1] : ""
        return String(name).withCString { languages -> String? in
            var spec = espeak_VOICE()
            spec.languages = languages
            guard let list = espeak_ListVoices(&spec), let best = list[0], let identifier = best.pointee.identifier else {
                return nil
            }
            return String(cString: identifier) + variant
        }
    }

    private static var defaultDataPath: String {
        Bundle.module.path(forResource: "espeak-ng-data", ofType: nil)
            ?? (Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("espeak-ng-data") } ?? "espeak-ng-data")
    }

    private static func voice(_ voice: espeak_VOICE) -> EspeakVoice {
        // Pairs of a priority byte and a zero-terminated language, ended by a zero priority.
        var languages: [String] = []
        if var at = voice.languages {
            while at.pointee != 0 {
                at += 1
                let language = String(cString: at)
                languages.append(language)
                at += strlen(at) + 1
            }
        }
        return EspeakVoice(name: voice.name.map { String(cString: $0) } ?? "",
                           identifier: voice.identifier.map { String(cString: $0) } ?? "",
                           languages: languages, gender: Int(voice.gender))
    }
}

// What espeak_Synth hands to the callback, gathered while the caller holds Espeak's lock. A C callback cannot
// capture, hence a global.
private var synthesized: [Int16] = []
#endif
