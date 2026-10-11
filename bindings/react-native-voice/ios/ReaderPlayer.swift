// Plays a VoicedText through AVAudioEngine and reports what is being heard.
import AVFoundation
import Foundation

/// Where a reader is, as the state event reports it.
struct ReaderSnapshot: Equatable {
    var character: Int
    var sentence: Int
    var time: Double
    var waiting: Bool
    var playing: Bool
    var finished: Bool
}

/// Plays a `VoicedText`: an `AVAudioSourceNode` pulls from `read(into:)` on the audio thread (which never waits), and a
/// timer reports the position. The position is that of the frames heard: those handed to the engine, less the output's
/// latency, mapped to the text by `character(atFrame:)`.
final class ReaderPlayer {
    let reader: VoicedText
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let manageSession: Bool
    private let onState: (ReaderSnapshot) -> Void
    private let onError: (Error) -> Void
    private let starts: [Int]
    private let queue = DispatchQueue(label: "speechwarp-voice.player")
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var base: Int64 = 0 // the reader's frame at the last seek (or 0)
    private var rendered: Int64 = 0 // frames handed to the engine since then
    private var ended = false // the reader had nothing more to give
    // The rest is changed on `queue` or under `lock`.
    private var playing = false
    private var finished = false
    private var released = false
    private var lastReported: ReaderSnapshot?
    private var lastError: NSError?
    private var endSeen: Date?

    init(reader: VoicedText, positionInterval: TimeInterval, manageSession: Bool,
         onState: @escaping (ReaderSnapshot) -> Void, onError: @escaping (Error) -> Void) throws {
        self.reader = reader
        self.manageSession = manageSession
        self.onState = onState
        self.onError = onError
        starts = reader.sentences.map(\.range.location)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(reader.sampleRate), channels: 1) else {
            throw NSError(domain: "speechwarp-voice", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio format at \(reader.sampleRate) Hz"])
        }
        source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audio -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audio)
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let wanted = Int(frameCount)
            let out = UnsafeMutableBufferPointer(start: data, count: wanted)
            let got = self?.render(into: out) ?? 0
            if got < wanted {
                UnsafeMutableBufferPointer(rebasing: out[got...]).update(repeating: 0)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: nil) { [weak self] _ in
            // The output changed (headphones out, say): the engine has stopped; carry on if playing.
            self?.queue.async { self?.restartIfPlaying() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.pause() // a call, say; the app plays again when it wants to
        })

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: max(0.016, positionInterval))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// On the audio thread.
    private func render(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if released { return 0 }
        let got = reader.read(into: out)
        rendered += Int64(got)
        if got == 0 && reader.isFinished { ended = true }
        return got
    }

    func play() {
        queue.async { [self] in
            guard !released else { return }
            if finished { seekLocked(0) } // played to the end: play again from the start
            do {
                if manageSession {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .spokenAudio)
                    try session.setActive(true)
                }
                try engine.start()
                playing = true
            } catch {
                onError(error)
            }
            report(force: true)
        }
    }

    func pause() {
        queue.async { [self] in
            guard !released else { return }
            engine.pause()
            playing = false
            report(force: true)
        }
    }

    func seek(toCharacter character: Int) {
        queue.async { [self] in
            guard !released else { return }
            seekLocked(character)
            report(force: true)
        }
    }

    func seek(toTime seconds: TimeInterval) {
        let character = min(max(seconds / reader.secondsPerCharacter, 0), Double(reader.text.utf16.count))
        seek(toCharacter: Int(character))
    }

    /// On `queue`.
    private func seekLocked(_ character: Int) {
        lock.lock()
        base = reader.seek(toCharacter: character)
        rendered = 0
        ended = false
        lock.unlock()
        finished = false
    }

    private func restartIfPlaying() {
        guard playing, !released, !engine.isRunning else { return }
        do { try engine.start() } catch { onError(error) }
    }

    /// Where it is (from any thread).
    func snapshot() -> ReaderSnapshot {
        queue.sync { snapshotNow() }
    }

    /// On `queue`.
    private func snapshotNow() -> ReaderSnapshot {
        lock.lock()
        let (base, rendered, ended) = (self.base, self.rendered, self.ended)
        lock.unlock()
        let session = AVAudioSession.sharedInstance()
        let latency = Int64((session.outputLatency + session.ioBufferDuration) * Double(reader.sampleRate))
        let heard = max(0, rendered - latency)
        let length = reader.text.utf16.count
        let character = min(max(Int(reader.character(atFrame: base + heard)), 0), length)
        var sentence = 0
        var low = 0, high = starts.count - 1
        while low <= high { // the last sentence starting at or before the character
            let mid = (low + high) / 2
            if starts[mid] <= character { sentence = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return ReaderSnapshot(
            character: character,
            sentence: sentence,
            time: Double(character) * reader.secondsPerCharacter,
            waiting: playing && !finished && !ended && heard >= rendered && reader.isWaiting,
            playing: playing,
            finished: finished)
    }

    /// On `queue`: the end, errors, and the position if it changed.
    private func tick() {
        guard !released else { return }
        if playing {
            lock.lock()
            let ended = self.ended
            lock.unlock()
            if !ended {
                endSeen = nil
            } else if let seen = endSeen {
                // Everything is handed over: stop once the output has had time to play it.
                let session = AVAudioSession.sharedInstance()
                if Date().timeIntervalSince(seen) >= session.outputLatency + session.ioBufferDuration {
                    endSeen = nil
                    finished = true
                    playing = false
                    engine.pause()
                    report(force: true)
                    return
                }
            } else {
                endSeen = Date()
            }
        }
        report(force: false)
    }

    /// On `queue`.
    private func report(force: Bool) {
        if let error = reader.lastError as NSError?, error !== lastError {
            lastError = error
            onError(error)
        }
        let state = snapshotNow()
        if force || state != lastReported {
            lastReported = state
            onState(state)
        }
    }

    func release() {
        queue.sync {
            lock.lock()
            released = true // no render reads again
            lock.unlock()
            timer?.cancel()
            timer = nil
        }
        engine.stop()
        reader.close()
    }
}
