import Flutter
import Foundation
import SpeechwarpVoice
import UIKit

/// speechwarp_voice on iOS: Dart's method channel "speechwarp_voice" makes and drives readers (`ReaderPlayer`, a
/// SpeechwarpVoice `VoicedText` played through AVAudioEngine), and the event channel "speechwarp_voice/positions"
/// reports where each one is.
public final class SpeechwarpVoicePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    /// The phonemizer for Kokoro voices when the app does not include speechwarp_voice_espeak (eSpeak NG is
    /// GPL-3.0-or-later; an app that cannot be GPL supplies its own). Set it from the app's own Swift, such as in
    /// the AppDelegate, before making a reader with a "kokoro:" voice. When it is nil, eSpeak's phonemizer is used if
    /// speechwarp_voice_espeak is there.
    public static var phonemizer: Phonemizer?

    private static let tick: TimeInterval = 0.05

    private var readers: [Int: ReaderPlayer] = [:]
    private var nextID = 1
    private var sink: FlutterEventSink?
    private var timer: Timer?
    private let engines = Engines()
    private let queue = DispatchQueue(label: "speechwarp_voice", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SpeechwarpVoicePlugin()
        let methods = FlutterMethodChannel(name: "speechwarp_voice", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: "speechwarp_voice/positions", binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
        registrar.publish(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        timer?.invalidate()
        timer = nil
        let all = readers.values
        readers = [:]
        queue.async { all.forEach { $0.close() } }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        startTicking()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "listVoices":
            let options = engineOptions(args["kokoroDirectory"] as? String, args["kokoroModelFile"] as? String)
            inBackground(result) { [engines] in engines.voices(options) }
        case "create":
            create(args, result)
        default:
            guard let id = args["id"] as? Int else {
                return result(FlutterError(code: "argument", message: "No reader id", details: nil))
            }
            guard let reader = readers[id] else {
                return result(FlutterError(code: "state", message: "No reader \(id): it has been disposed", details: nil))
            }
            switch call.method {
            case "play": reader.play()
            case "pause": reader.pause()
            case "seek": reader.seek(toCharacter: args["character"] as? Int ?? 0)
            case "setSpeed": reader.setSpeed((args["speed"] as? NSNumber)?.floatValue ?? 1)
            case "configure": reader.configure(args["settings"] as? [String: Any] ?? [:])
            case "setVoice":
                guard let voiceID = args["voiceId"] as? String else {
                    return result(FlutterError(code: "argument", message: "No voiceId", details: nil))
                }
                reader.setVoice(voiceID)
            case "position": break
            case "dispose":
                readers[id] = nil
                queue.async { reader.close() }
                return result(nil)
            default:
                return result(FlutterMethodNotImplemented)
            }
            result(reader.position(id: id))
            startTicking()
        }
    }

    private func create(_ args: [String: Any], _ result: @escaping FlutterResult) {
        guard let text = args["text"] as? String, let voiceID = args["voiceId"] as? String else {
            return result(FlutterError(code: "argument", message: "No text or voiceId", details: nil))
        }
        let options = args["options"] as? [String: Any] ?? [:]
        let id = nextID
        nextID += 1
        let factory = engines.factory(engineOptions(options["kokoroDirectory"] as? String,
                                                    options["kokoroModelFile"] as? String))
        inBackground(result) { [weak self] in
            let reader = try ReaderPlayer(text: text, voiceID: voiceID, factory: factory, options: options)
            DispatchQueue.main.async {
                if let self { self.readers[id] = reader } else { reader.close() }
            }
            return ["id": id, "sampleRate": reader.sampleRate, "sentences": reader.sentenceRanges()] as [String: Any]
        }
    }

    private func engineOptions(_ kokoroDirectory: String?, _ kokoroModelFile: String?) -> [String: Any] {
        var options: [String: Any] = [:]
        options["kokoroDirectory"] = kokoroDirectory
        options["kokoroModelFile"] = kokoroModelFile
        options["phonemizer"] = Self.phonemizer
        return options
    }

    private func inBackground(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any?) {
        queue.async {
            do {
                let value = try work()
                DispatchQueue.main.async { result(value) }
            } catch {
                let code = (error as? EngineError)?.code ?? "error"
                DispatchQueue.main.async {
                    result(FlutterError(code: code, message: Self.describe(error), details: nil))
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }

    // Sends every reader's position while any is playing, `tick` apart, and once more after the last stops.
    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            var active = false
            for (id, reader) in self.readers {
                let changed = reader.takeChanged()
                if reader.isPlaying || changed {
                    self.sink?(reader.position(id: id))
                    active = active || reader.isPlaying
                }
            }
            if !active || self.sink == nil {
                timer.invalidate()
                self.timer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timer.fire()
    }
}
