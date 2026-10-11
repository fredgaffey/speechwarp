// What the Objective-C++ TurboModule (RNSpeechwarpVoice.mm) calls: readers made by id, played natively. The reading
// itself is the Swift package's VoicedText, copied into this pod by scripts/vendor.sh.
import AVFoundation
import Foundation

@objc(SpeechwarpVoiceBridge)
public final class SpeechwarpVoiceBridge: NSObject {
    /// Called with each state and error event, on a background queue.
    @objc public var onState: ((NSDictionary) -> Void)?
    @objc public var onError: ((NSDictionary) -> Void)?

    private let lock = NSLock()
    private var players: [Int: ReaderPlayer] = [:]
    private var aheadToDisk: [Int: Flag] = [:]
    private var nextHandle = 1
    private let worker = DispatchQueue(label: "speechwarp-voice", qos: .userInitiated, attributes: .concurrent)

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var get: Bool { lock.locked { value } }
        func set(_ newValue: Bool) { lock.locked { value = newValue } }
    }

    /// Any voice by id: Apple's own, or an engine package's.
    static func makeVoice(_ id: String) throws -> SentenceVoice {
        if id.hasPrefix(AppleSentenceVoice.idPrefix) { return try AppleSentenceVoice(identifier: id) }
        if let provider = VoiceProviders.find(id) { return try provider.makeVoice(id: id) }
        throw NSError(domain: "speechwarp-voice", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "No engine for the voice \"\(id)\". Voices are \"apple:...\"; \"espeak:...\" needs "
            + "react-native-speechwarp-voice-espeak and \"kokoro:...\" react-native-speechwarp-voice-kokoro."])
    }

    @objc public func listVoices(resolve: @escaping (NSArray) -> Void, reject: @escaping (String) -> Void) {
        worker.async {
            do {
                var voices = SpeechVoice.all.map {
                    VoiceInfo(id: AppleSentenceVoice.idPrefix + $0.identifier, name: $0.name, language: $0.language,
                              engine: "apple")
                }
                for provider in VoiceProviders.all() { voices += try provider.voices() }
                resolve(voices.map(\.dictionary) as NSArray)
            } catch {
                reject(error.localizedDescription)
            }
        }
    }

    @objc public func createReader(_ text: String, voiceId: String, options: NSDictionary,
                                   resolve: @escaping (NSDictionary) -> Void, reject: @escaping (String) -> Void) {
        worker.async { [self] in
            do {
                let flag = Flag((options["speakAheadToDisk"] as? Bool) ?? false)
                var settings = VoicedText.Options()
                if let rate = options["sampleRate"] as? NSNumber { settings.sampleRate = rate.intValue }
                if let speedUp = options["speedUp"] as? Bool { settings.speedUp = speedUp }
                if let value = options["lookahead"] as? NSNumber { settings.lookahead = value.doubleValue }
                if let value = options["keptLookahead"] as? NSNumber { settings.keptLookahead = value.doubleValue }
                if let value = options["secondsPerCharacter"] as? NSNumber { settings.secondsPerCharacter = value.doubleValue }
                if (options["cache"] as? Bool) != false {
                    settings.cacheDirectory = (options["cacheDirectory"] as? String).map { URL(fileURLWithPath: $0) }
                        ?? VoiceCache.defaultDirectory
                }
                settings.speakAheadToDisk = { flag.get }
                let reader = try VoicedText(text, voiceID: voiceId, factory: Self.makeVoice, options: settings)
                if let speed = options["speed"] as? NSNumber { reader.speed = speed.floatValue }
                let handle = lock.locked { () -> Int in
                    defer { nextHandle += 1 }
                    return nextHandle
                }
                let player = try ReaderPlayer(
                    reader: reader,
                    positionInterval: (options["positionInterval"] as? NSNumber)?.doubleValue ?? 0.1,
                    manageSession: (options["manageAudioSession"] as? Bool) ?? true,
                    onState: { [weak self] state in self?.onState?(Self.dictionary(handle, state)) },
                    onError: { [weak self] error in
                        self?.onError?(["reader": handle, "message": error.localizedDescription])
                    })
                lock.locked {
                    players[handle] = player
                    aheadToDisk[handle] = flag
                }
                resolve(["handle": handle, "sampleRate": reader.sampleRate, "duration": reader.duration,
                         "sentenceCount": reader.sentences.count, "voiceId": reader.voiceID])
            } catch {
                reject(error.localizedDescription)
            }
        }
    }

    private func player(_ handle: Int) -> ReaderPlayer? { lock.locked { players[handle] } }

    @objc public func play(_ handle: Int) { player(handle)?.play() }
    @objc public func pause(_ handle: Int) { player(handle)?.pause() }
    @objc public func seek(_ handle: Int, toCharacter character: Int) { player(handle)?.seek(toCharacter: character) }
    @objc public func seek(_ handle: Int, toTime seconds: Double) { player(handle)?.seek(toTime: seconds) }
    @objc public func setSpeed(_ handle: Int, speed: Double) { player(handle)?.reader.speed = Float(speed) }
    @objc public func setVoice(_ handle: Int, voiceId: String) { player(handle)?.reader.setVoice(id: voiceId) }
    @objc public func setSpeakAheadToDisk(_ handle: Int, enabled: Bool) {
        lock.locked { aheadToDisk[handle] }?.set(enabled)
    }

    @objc public func configure(_ handle: Int, settings: NSDictionary) {
        func number(_ key: String) -> Float? { (settings[key] as? NSNumber)?.floatValue }
        player(handle)?.reader.configure { stream in
            if let value = number("nonlinear") { stream.nonlinear = value }
            if let value = number("pauseCap") { stream.pauseCap = value }
            if let value = settings["keepSpeed"] as? Bool { stream.keepSpeed = value }
            if let value = number("speedFloor") { stream.speedFloor = value }
            if let value = number("rhythmGap") { stream.rhythmGap = value }
            if let value = number("rhythmRate") { stream.rhythmRate = value }
            if let value = number("heardPause") { stream.setHeardPause(value, fromSpeed: number("heardPauseFrom") ?? 0) }
            if let value = number("floorBlend") {
                stream.setFloorBlend(value, fromSpeed: number("floorBlendFrom") ?? 0, fullSpeed: number("floorBlendFull") ?? 0)
            }
        }
    }

    @objc public func state(_ handle: Int) -> NSDictionary {
        guard let player = player(handle) else { return [:] }
        return Self.dictionary(handle, player.snapshot())
    }

    @objc public func sentences(_ handle: Int) -> NSArray {
        guard let player = player(handle) else { return [] }
        return player.reader.sentences.map { ["start": $0.range.location, "length": $0.range.length] } as NSArray
    }

    @objc public func releaseReader(_ handle: Int) {
        let player: ReaderPlayer? = lock.locked {
            aheadToDisk[handle] = nil
            return players.removeValue(forKey: handle)
        }
        if let player { worker.async { player.release() } }
    }

    @objc public func defaultCacheDirectory() -> String { VoiceCache.defaultDirectory.path }

    @objc public func invalidate() {
        let all: [ReaderPlayer] = lock.locked {
            defer { players = [:]; aheadToDisk = [:] }
            return Array(players.values)
        }
        all.forEach { $0.release() }
    }

    private static func dictionary(_ handle: Int, _ state: ReaderSnapshot) -> NSDictionary {
        ["reader": handle, "character": state.character, "sentence": state.sentence, "time": state.time,
         "waiting": state.waiting, "playing": state.playing, "finished": state.finished]
    }
}
