import AVFoundation
import Foundation
import Speechwarp
import SpeechwarpVoice

/// A `VoicedText` played through AVAudioEngine: a source node pulls what the reader has ready on the audio thread
/// (the reader's `read` never waits), with silence when the next sentence is not spoken yet. Safe to call from any
/// thread; made on a background thread, because the first voice may take a moment to start.
final class ReaderPlayer: @unchecked Sendable {
    private let reader: VoicedText
    let sampleRate: Int

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let lock = NSLock()
    private var rendered: Int64 = 0 // frames given to the engine since the last seek
    private var seekFrame: Int64 = 0 // the reader's frame at the last seek
    private var playing = false
    private var finished = false
    private var ended = false // the reader has run dry; finished once the output has played what it was given
    private var endSeen: Date?
    private var closed = false
    private var changed = true

    init(text: String, voiceID: String, factory: @escaping (String) throws -> SentenceVoice, options: [String: Any]) throws {
        var readerOptions = VoicedText.Options()
        if let value = options["lookahead"] as? NSNumber { readerOptions.lookahead = value.doubleValue }
        if let value = options["keptLookahead"] as? NSNumber { readerOptions.keptLookahead = value.doubleValue }
        if let value = options["secondsPerCharacter"] as? NSNumber { readerOptions.secondsPerCharacter = value.doubleValue }
        if options["cache"] as? Bool ?? true {
            readerOptions.cacheDirectory = (options["cacheDirectory"] as? String).map { URL(fileURLWithPath: $0) }
                ?? VoiceCache.defaultDirectory
        }
        reader = try VoicedText(text, voiceID: voiceID, factory: factory, options: readerOptions)
        sampleRate = reader.sampleRate
        if let speed = options["speed"] as? NSNumber { reader.speed = speed.floatValue }
        if let settings = options["speedUp"] as? [String: Any] { configure(settings) }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            reader.close()
            throw EngineError(code: "error", message: "No audio format at \(sampleRate) Hz")
        }
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let samples = UnsafeMutableBufferPointer(start: data, count: Int(frameCount))
            let frames = self.render(into: samples)
            if frames < samples.count {
                samples.baseAddress!.advanced(by: frames).initialize(repeating: 0, count: samples.count - frames)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    // On the audio thread.
    private func render(into samples: UnsafeMutableBufferPointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard playing, !ended, !closed else { return 0 }
        let frames = reader.read(into: samples)
        rendered += Int64(frames)
        if frames == 0 && reader.isFinished { ended = true }
        return frames
    }

    var isPlaying: Bool { lock.locked { playing } }

    /// True once after anything that the position should report has changed.
    /// Called on the main thread (repeatedly while playing), which also finishes once the reader has run dry and
    /// the output has had time to play the last of it, and then stops the engine.
    func takeChanged() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        let (was, done): (Bool, Bool) = lock.locked {
            if playing && ended {
                if let seen = endSeen {
                    if Date().timeIntervalSince(seen) >= latency {
                        endSeen = nil
                        finished = true
                        playing = false
                        changed = true
                    }
                } else {
                    endSeen = Date()
                }
            }
            let was = changed
            changed = false
            return (was, finished)
        }
        if done && engine.isRunning { engine.pause() }
        return was
    }

    /// Throws when the audio engine cannot start (another app holds the audio, no output).
    func play() throws {
        let restart: Bool = lock.locked { finished }
        if restart { seek(toCharacter: 0) }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        lock.locked {
            playing = true
            changed = true
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                lock.locked {
                    playing = false
                    changed = true
                }
                throw error
            }
        }
    }

    func pause() {
        lock.locked {
            playing = false
            changed = true
        }
        engine.pause()
    }

    func seek(toCharacter character: Int) {
        lock.locked {
            seekFrame = reader.seek(toCharacter: character)
            rendered = 0
            finished = false
            ended = false
            endSeen = nil
            changed = true
        }
    }

    func setSpeed(_ speed: Float) {
        reader.speed = speed
        lock.locked { changed = true }
    }

    func setVoice(_ id: String) {
        reader.setVoice(id: id)
        lock.locked { changed = true }
    }

    func configure(_ settings: [String: Any]) {
        func f(_ key: String) -> Float? { (settings[key] as? NSNumber)?.floatValue }
        reader.configure { stream in
            if let v = f("nonlinear") { stream.nonlinear = v }
            if let v = f("pauseCap") { stream.pauseCap = v }
            if let v = settings["keepSpeed"] as? Bool { stream.keepSpeed = v }
            if let v = f("speedFloor") { stream.speedFloor = v }
            if let v = f("rhythmGap") { stream.rhythmGap = v }
            if let v = f("rhythmRate") { stream.rhythmRate = v }
            if let pause = f("heardPause"), let from = f("heardPauseFrom") { stream.setHeardPause(pause, fromSpeed: from) }
            if let blend = f("floorBlend"), let from = f("floorBlendFrom"), let full = f("floorBlendFull") {
                stream.setFloorBlend(blend, fromSpeed: from, fullSpeed: full)
            }
        }
        lock.locked { changed = true }
    }

    /// The sentences as start, length, start, length ... in UTF-16 units.
    func sentenceRanges() -> [Int] {
        reader.sentences.flatMap { [$0.range.location, $0.range.length] }
    }

    /// What is being heard, for Dart's `ReaderPosition.fromMap`.
    func position(id: Int) -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        // What has gone to the engine but is not heard yet: the output's latency and one I/O buffer.
        let latency = Int64((session.outputLatency + session.ioBufferDuration) * Double(sampleRate))
        let (heard, isPlaying, isFinished): (Int64, Bool, Bool) = lock.locked {
            (seekFrame + max(0, rendered - (playing ? latency : 0)), playing, finished)
        }
        let length = reader.text.utf16.count
        let character = min(max(Int(reader.character(atFrame: heard)), 0), length)
        var map: [String: Any] = [
            "reader": id,
            "character": character,
            "sentence": sentence(at: character),
            "time": Double(character) * reader.secondsPerCharacter,
            "playing": isPlaying,
            "waiting": isPlaying && reader.isWaiting,
            "finished": isFinished,
            "voiceId": reader.voiceID,
        ]
        if let error = reader.lastError { map["error"] = SpeechwarpVoicePlugin.describe(error) }
        return map
    }

    /// Stops the engine and the reader's thread.
    func close() {
        lock.locked {
            closed = true
            playing = false
        }
        engine.stop()
        reader.close()
    }

    private func sentence(at character: Int) -> Int {
        let sentences = reader.sentences
        var low = 0, high = sentences.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sentences[mid].range.location <= character { low = mid } else { high = mid - 1 }
        }
        return max(low, 0)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
