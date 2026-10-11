#if canImport(AVFoundation) && canImport(NaturalLanguage) && canImport(CryptoKit)
import Foundation
import Speechwarp

/// A text read aloud by any `SentenceVoice` (Apple's voices, Kokoro, eSpeak NG ...), sentence by sentence, spoken
/// on a thread of its own ahead of what is being read, optionally sped up by speechwarp. The voice can change
/// between sentences. The same reader as the C# `VoicedText`.
///
/// ```swift
/// let book = try VoicedText(text, voice: try AppleSentenceVoice(identifier: "com.apple.eloquence.en-US.Reed"))
/// book.speed = 3
/// book.configure { $0.setHeardPause(0.03, fromSpeed: 3) }
/// // on the audio thread:
/// let samples = book.read(maxFrames: 1024)        // mono, book.sampleRate; never waits
/// // for the display:
/// let at = book.characterPosition                 // UTF-16 offset into the text
/// // from the next sentence on, another voice:
/// book.setVoice(try AppleSentenceVoice(identifier: "com.apple.eloquence.en-US.Flo"))
/// ```
///
/// Sentences are spoken on the reader's own background thread, one at a time, until `lookahead` seconds of
/// listening are ready (`keptLookahead` for a slow voice). `read` never waits: if the next sentence is not spoken
/// yet it returns what there is, and `isWaiting` says so. A slow voice's sentences are kept on disk in a
/// `VoiceCache` when `Options.cacheDirectory` is given, and read from there next time. Everything is safe to call
/// from any thread.
///
/// Two clocks: the frames `read` returns, counted from the frame the last seek returned; and the timeline, the
/// text's characters (UTF-16) at `secondsPerCharacter` each, which is the same whatever the voice and the speed.
/// `time(atFrame:)` maps the first to the second.
///
/// The reader's thread stops when the reader is released or `close()` is called.
public final class VoicedText: @unchecked Sendable {
    /// How a reader reads: its output, how far ahead it speaks, and where it keeps what slow voices say.
    public struct Options {
        /// The sample rate of what `read` returns. Default (nil): the first voice's. Voices that speak at another
        /// rate are converted to it.
        public var sampleRate: Int?
        /// Whether the audio goes through a `SpeechwarpStream`, so that `speed` and `configure` work. False gives
        /// the voices' audio as spoken, for a player that speeds it up itself.
        public var speedUp: Bool
        /// Seconds of listening to keep spoken ahead of what is being read, for a fast voice.
        public var lookahead: TimeInterval
        /// Seconds of listening to keep spoken ahead for a slow voice (`keepsSpoken`).
        public var keptLookahead: TimeInterval
        /// The pace of the timeline: a character of the text is this many seconds long, whatever the voice, so
        /// that a place is the same character in every voice. Default 1/17, about Apple's voices at their normal
        /// rate.
        public var secondsPerCharacter: Double
        /// Where a slow voice's sentences are kept (`VoiceCache.defaultDirectory` is the usual place). Nil keeps
        /// nothing on disk.
        public var cacheDirectory: URL?
        /// Asked when everything within the lookahead is spoken: true lets a slow voice carry on speaking whole
        /// blocks into the cache beyond it (while the device is charging, say). Needs `cacheDirectory`. Called on
        /// the reader's thread.
        public var speakAheadToDisk: (() -> Bool)?

        public init(sampleRate: Int? = nil, speedUp: Bool = true, lookahead: TimeInterval = 30,
                    keptLookahead: TimeInterval = 120, secondsPerCharacter: Double = 1 / 17.0,
                    cacheDirectory: URL? = nil, speakAheadToDisk: (() -> Bool)? = nil) {
            self.sampleRate = sampleRate
            self.speedUp = speedUp
            self.lookahead = lookahead
            self.keptLookahead = keptLookahead
            self.secondsPerCharacter = secondsPerCharacter
            self.cacheDirectory = cacheDirectory
            self.speakAheadToDisk = speakAheadToDisk
        }
    }

    /// The text being read.
    public let text: String
    /// The text cut into sentences.
    public let sentences: [SpokenText.Sentence]
    /// The sample rate of what `read` returns. Mono.
    public let sampleRate: Int
    /// The timeline's pace: seconds a character.
    public let secondsPerCharacter: Double
    /// The length of the timeline: every UTF-16 character at `secondsPerCharacter`.
    public var duration: TimeInterval { Double(length) * secondsPerCharacter }
    /// Whether the audio goes through speechwarp (`Options.speedUp`).
    public var speedsUp: Bool { stream != nil }

    private let lock = NSLock()
    private let wake = Wake()
    private let factory: ((String) throws -> SentenceVoice)?
    private let cacheDirectory: URL?
    private let speakAheadToDisk: (() -> Bool)?
    private let stream: SpeechwarpStream?
    private let length: Int

    private var currentVoice: SentenceVoice
    private var currentID: String
    private var cache: VoiceCache?
    private var pendingID: String?
    private var generation = 0 // raised by a new voice: what was being spoken before it is not used
    private var ahead: TimeInterval
    private var keptAhead: TimeInterval
    private var ready: [Int: [Float]] = [:] // at sampleRate; empty for nothing to say (or a failure)
    private var building: [Int: [[Float]?]] = [:]
    private var segments: [(inputStart: Int64, sentence: Int, frames: Int, total: Int)] = []
    private var marks: [(frame: Int64, character: Double)] = [(0, 0)]
    private var feeding = 0 // the sentence being read (or written into the stream)
    private var fed = 0 // frames of it taken
    private var input: Int64 = 0 // frames of speech taken since the last seek
    private var frame: Int64 = 0 // frames returned, counted from the frame the last seek returned
    private var flushed = false
    private var waiting = false
    private var failure: Error?
    private var closed = false

    /// Reads `text` with `voice`, starting to speak the first sentences at once.
    public convenience init(_ text: String, voice: SentenceVoice, options: Options = Options()) throws {
        try self.init(text, voice: voice, voiceID: voice.id, factory: nil, options: options)
    }

    /// Reads `text` with the voice `factory` makes for `voiceID` (made now, on this thread). `setVoice(id:)`
    /// makes later voices the same way, on the reader's thread.
    public convenience init(_ text: String, voiceID: String, factory: @escaping (String) throws -> SentenceVoice,
                            options: Options = Options()) throws {
        try self.init(text, voice: try factory(voiceID), voiceID: voiceID, factory: factory, options: options)
    }

    private init(_ text: String, voice: SentenceVoice, voiceID: String,
                 factory: ((String) throws -> SentenceVoice)?, options: Options) throws {
        precondition(options.secondsPerCharacter > 0, "secondsPerCharacter must be more than 0")
        self.text = text
        length = text.utf16.count
        sentences = SpokenText.split(text)
        currentVoice = voice
        currentID = voiceID
        self.factory = factory
        cacheDirectory = options.cacheDirectory
        speakAheadToDisk = options.speakAheadToDisk
        ahead = max(1, options.lookahead)
        keptAhead = max(1, options.keptLookahead)
        secondsPerCharacter = options.secondsPerCharacter
        sampleRate = options.sampleRate ?? voice.sampleRate
        stream = options.speedUp ? try SpeechwarpStream(sampleRate: sampleRate, channels: 1) : nil
        cache = cacheFor(voice)
        let wake = self.wake
        let thread = Thread { [weak self] in
            while true {
                // Only a weak hold between sentences, so that releasing the reader stops the thread.
                guard let worked = self?.step() else { break }
                if !worked { wake.wait(seconds: 0.5) }
            }
        }
        thread.name = "SpeechwarpVoice reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        wake.signal()
    }

    /// The voice reading now (until one asked for by `setVoice(id:)` has been made).
    public var voice: SentenceVoice { lock.locked { currentVoice } }

    /// The id of the voice reading, or of the voice asked for if it has not taken over yet: the id given to the
    /// factory for a voice it made, otherwise the voice's `id`.
    public var voiceID: String { lock.locked { pendingID ?? currentID } }

    /// speechwarp's speed: 2 plays twice as fast as the voice speaks. Default 1. Ignored (always 1) when the
    /// reader does not speed up.
    public var speed: Float {
        get { lock.locked { stream?.speed ?? 1 } }
        set { lock.locked { stream?.speed = newValue }; wake.signal() }
    }

    /// Seconds of listening to keep spoken ahead for a fast voice. At least 1.
    public var lookahead: TimeInterval {
        get { lock.locked { ahead } }
        set { lock.locked { ahead = max(1, newValue) }; wake.signal() }
    }

    /// Seconds of listening to keep spoken ahead for a slow voice (`keepsSpoken`). At least 1.
    public var keptLookahead: TimeInterval {
        get { lock.locked { keptAhead } }
        set { lock.locked { keptAhead = max(1, newValue) }; wake.signal() }
    }

    /// The UTF-16 offset in the text of what `read` has reached (approximate within a sentence).
    public var characterPosition: Int { lock.locked { Int(reached()) } }

    /// The place on the timeline of what `read` has reached, in seconds.
    public var position: TimeInterval { lock.locked { reached() } * secondsPerCharacter }

    /// The sentence `read` has reached.
    public var sentenceIndex: Int { lock.locked { sentenceAt(Int(reached())) } }

    /// The last `read` returned less than asked because the next sentence was still being spoken.
    public var isWaiting: Bool { lock.locked { waiting } }

    /// The same as `isWaiting`.
    public var isBuffering: Bool { isWaiting }

    /// Everything has been read.
    public var isFinished: Bool {
        lock.locked {
            guard let stream else { return feeding >= sentences.count }
            return flushed && stream.framesAvailable == 0
        }
    }

    /// The most recent failure to speak a sentence (which is then skipped) or to make a voice, if any.
    public var lastError: Error? { lock.locked { failure } }

    /// Changes the speechwarp stream's other settings (nonlinear amount, heard pause, floor blend, rhythm ...)
    /// safely. Do not keep the stream. Does nothing when the reader does not speed up.
    public func configure(_ body: (SpeechwarpStream) -> Void) {
        lock.locked { if let stream { body(stream) } }
        wake.signal()
    }

    /// Carries on in the voice the factory makes for `id`. The voice is made on the reader's thread (it may take a
    /// while, a neural model say), so this returns at once; once it is made it reads from the next sentence not yet
    /// started. A failure to make it is reported in `lastError` and the old voice carries on. Needs a reader made
    /// with a factory.
    public func setVoice(id: String) {
        precondition(factory != nil, "This reader was made with a voice, not a factory: pass a SentenceVoice")
        lock.locked { pendingID = id }
        wake.signal()
    }

    /// Carries on in `voice` from the next sentence not yet started (what is spoken in the old voice beyond that is
    /// dropped).
    public func setVoice(_ voice: SentenceVoice) {
        lock.locked {
            pendingID = nil // this one wins over any still being made
            install(voice, id: voice.id)
        }
        wake.signal()
    }

    /// Returns up to `maxFrames` mono samples to play next; fewer when the next sentence is not spoken yet
    /// (`isWaiting`) or at the end. Never waits.
    public func read(maxFrames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: maxFrames)
        let frames = samples.withUnsafeMutableBufferPointer { read(into: $0) }
        samples.removeLast(maxFrames - frames)
        return samples
    }

    /// Fills `samples` with what to play next (mono); returns the frames written. Never waits.
    public func read(into samples: UnsafeMutableBufferPointer<Float>) -> Int {
        let (frames, advanced): (Int, Bool) = lock.locked {
            if closed { return (0, false) }
            let before = feeding
            let frames: Int
            if let stream {
                feed(stream, until: samples.count)
                frames = stream.read(into: samples)
                waiting = frames < samples.count && !flushed
            } else {
                frames = copy(into: samples)
                waiting = frames < samples.count && feeding < sentences.count
            }
            if frames > 0 {
                frame += Int64(frames)
                marks.append((frame, reached()))
                if marks.count > 4000 { marks.removeFirst(2000) }
            }
            return (frames, feeding != before)
        }
        if advanced || frames < samples.count { wake.signal() }
        return frames
    }

    /// Continues from the start of the sentence containing UTF-16 offset `offset`; returns the frame that start
    /// has on the timeline (its time × `sampleRate`), from which later frames are counted.
    @discardableResult
    public func seek(toCharacter offset: Int) -> Int64 {
        let result: Int64 = lock.locked {
            feeding = sentenceAt(min(max(offset, 0), length))
            fed = 0
            stream?.reset()
            flushed = false
            segments = []
            input = 0
            let start = sentences.indices.contains(feeding) ? sentences[feeding].range.location : length
            frame = Int64((Double(start) * secondsPerCharacter * Double(sampleRate)).rounded())
            marks = [(frame, Double(start))]
            ready = ready.filter { $0.key >= feeding } // what is spoken from here on still serves
            waiting = false
            return frame
        }
        wake.signal()
        return result
    }

    /// Continues from the start of the sentence at `time` seconds on the timeline; returns its frame.
    @discardableResult
    public func seek(toTime time: TimeInterval) -> Int64 {
        seek(toCharacter: Int(min(max(time / secondsPerCharacter, 0), Double(length))))
    }

    /// The place on the timeline, in seconds, of frame `frame` of what `read` returned, counted from the frame the
    /// last seek returned (0 before any). Recent frames only: it remembers the last few thousand reads.
    public func time(atFrame frame: Int64) -> TimeInterval {
        character(atFrame: frame) * secondsPerCharacter
    }

    /// The UTF-16 offset at frame `frame` (see `time(atFrame:)`), fractional within a sentence.
    public func character(atFrame frame: Int64) -> Double {
        lock.locked {
            guard let i = marks.lastIndex(where: { $0.frame <= frame }) else { return marks[0].character }
            let (from, character) = marks[i]
            guard i + 1 < marks.count, marks[i + 1].frame > from else { return character }
            let next = marks[i + 1]
            return character + (next.character - character) * Double(frame - from) / Double(next.frame - from)
        }
    }

    /// Stops the reader's thread (after the sentence it is speaking); `read` returns nothing from then on.
    public func close() {
        lock.locked { closed = true }
        wake.signal()
    }

    // MARK: Reading (with the lock held)

    private func feed(_ stream: SpeechwarpStream, until wanted: Int) {
        while stream.framesAvailable < wanted && !flushed {
            if feeding >= sentences.count {
                try? stream.flush()
                flushed = true
                return
            }
            guard let audio = ready[feeding] else { return } // not spoken yet
            let take = min(4096, audio.count - fed)
            if take > 0 {
                audio.withUnsafeBufferPointer { all in
                    try? stream.write(UnsafeBufferPointer(rebasing: all[fed..<fed + take]))
                }
                taken(take, of: audio.count)
            }
            if fed >= audio.count { advance() }
        }
    }

    private func copy(into samples: UnsafeMutableBufferPointer<Float>) -> Int {
        var written = 0
        while written < samples.count, feeding < sentences.count, let audio = ready[feeding] {
            let take = min(samples.count - written, audio.count - fed)
            if take > 0 {
                audio.withUnsafeBufferPointer { all in
                    _ = UnsafeMutableBufferPointer(rebasing: samples[written..<written + take])
                        .initialize(from: UnsafeBufferPointer(rebasing: all[fed..<fed + take]))
                }
                written += take
                taken(take, of: audio.count)
            }
            if fed >= audio.count { advance() }
        }
        return written
    }

    private func taken(_ take: Int, of total: Int) {
        if let last = segments.last, last.sentence == feeding {
            segments[segments.count - 1].frames += take
        } else {
            segments.append((input, feeding, take, total))
        }
        input += Int64(take)
        fed += take
        // Segments wholly behind what is heard are no longer needed.
        if segments.count > 64 {
            let heard = self.heard()
            if let keep = segments.lastIndex(where: { $0.inputStart <= heard }), keep > 0 {
                segments.removeFirst(keep)
            }
        }
    }

    private func advance() {
        feeding += 1
        fed = 0
        ready = ready.filter { $0.key >= feeding - 2 } // a little is kept behind for short seeks
    }

    /// Frames of speech (before any speed-up) heard since the last seek.
    private func heard() -> Int64 { stream?.position ?? input }

    /// The UTF-16 offset reached, fractional within a sentence.
    private func reached() -> Double {
        let heard = self.heard()
        guard let segment = segments.last(where: { $0.inputStart <= heard }) else {
            return Double(sentences.indices.contains(feeding) ? sentences[feeding].range.location : length)
        }
        let range = sentences[segment.sentence].range
        let into = min(max(Double(heard - segment.inputStart) / Double(max(1, segment.total)), 0), 1)
        return Double(range.location) + into * Double(range.length)
    }

    private func sentenceAt(_ offset: Int) -> Int {
        sentences.lastIndex { $0.range.location <= offset } ?? 0
    }

    // MARK: Speaking ahead, on the reader's thread

    /// One piece of work. False when there was nothing to do; nil when the reader is closed.
    private func step() -> Bool? {
        if lock.locked({ closed }) { return nil }
        if takePendingVoice() { return true }
        return speakNext()
    }

    /// Makes the voice asked for by id and puts it in place. False when none was asked for.
    private func takePendingVoice() -> Bool {
        guard let id = lock.locked({ pendingID }) else { return false }
        do {
            let next = try factory!(id)
            lock.locked {
                guard pendingID == id else { return } // another voice was asked for meanwhile; that one wins
                pendingID = nil
                install(next, id: id)
            }
        } catch {
            lock.locked {
                failure = error
                if pendingID == id { pendingID = nil } // carry on in the old voice
            }
        }
        return true
    }

    /// Puts `next` in place from the next sentence not yet started (with the lock held).
    private func install(_ next: SentenceVoice, id: String) {
        currentVoice = next
        currentID = id
        cache = cacheFor(next)
        building = [:]
        generation += 1
        ready = ready.filter { $0.key < feeding || ($0.key == feeding && fed > 0) }
    }

    /// Speaks (or loads from the cache) the next sentence missing within the lookahead. False when none is.
    private func speakNext() -> Bool {
        let (index, generation, speaker, cache): (Int?, Int, SentenceVoice, VoiceCache?) = lock.locked {
            (nextMissing(currentVoice.keepsSpoken ? keptAhead : ahead), self.generation, currentVoice, self.cache)
        }
        guard let index else {
            guard let cache, let ask = speakAheadToDisk, ask() else { return false }
            return speakAheadToDisk(speaker, cache, generation)
        }
        let block = VoiceCache.block(of: index)
        if let cache, let kept = cache.load(block, sampleRate: sampleRate) {
            let filled: Bool = lock.locked {
                guard generation == self.generation else { return true }
                for (i, audio) in kept.enumerated() {
                    let sentence = block * VoiceCache.blockSize + i
                    if sentence >= feeding && sentence < sentences.count && ready[sentence] == nil {
                        ready[sentence] = audio
                    }
                }
                // A seek past it while it loaded leaves it unneeded, not short.
                return ready[index] != nil || index < feeding
            }
            if filled { return true }
            cache.remove(block) // shorter than it should be: speak it again
        }
        let spoken = speak(speaker, index)
        let current: Bool = lock.locked {
            guard generation == self.generation else { return false }
            if index >= feeding { ready[index] = spoken ?? [] }
            return true
        }
        if current, let cache { build(cache, index, spoken, generation) }
        return true
    }

    /// The first sentence from the one being read that is not spoken, within `lookahead` s; nil for none.
    private func nextMissing(_ lookahead: TimeInterval) -> Int? {
        let speed = Double(max(stream?.speed ?? 1, 0.05))
        var seconds = 0.0
        var i = feeding
        while i < sentences.count && seconds < lookahead {
            guard let audio = ready[i] else { return i }
            seconds += Double(audio.count - (i == feeding ? fed : 0)) / Double(sampleRate) / speed
            i += 1
        }
        return nil
    }

    /// The sentence spoken and converted to `sampleRate`; nil if the voice failed.
    private func speak(_ speaker: SentenceVoice, _ index: Int) -> [Float]? {
        do {
            let samples = try speaker.speak(sentences[index].text)
            return speaker.sampleRate == sampleRate
                ? samples : Resampling.linear(samples, from: speaker.sampleRate, to: sampleRate)
        } catch {
            lock.locked { failure = error }
            return nil
        }
    }

    /// Adds a sentence to its block, and keeps the block once every sentence of it is spoken.
    private func build(_ cache: VoiceCache, _ index: Int, _ spoken: [Float]?, _ generation: Int) {
        let block = VoiceCache.block(of: index)
        let complete: [[Float]]? = lock.locked {
            guard generation == self.generation else { return nil }
            guard let spoken else {
                building[block] = nil // a failure is not kept: the block is spoken again another time
                return nil
            }
            var parts = building[block]
                ?? [[Float]?](repeating: nil, count: min(VoiceCache.blockSize, sentences.count - block * VoiceCache.blockSize))
            parts[index % VoiceCache.blockSize] = spoken
            // Blocks left part-spoken by a seek are let go.
            building = building.filter { $0.key >= VoiceCache.block(of: feeding) }
            if parts.allSatisfy({ $0 != nil }) {
                building[block] = nil
                return parts.map { $0! }
            }
            building[block] = parts
            return nil
        }
        if let complete { keep(cache, block, complete) }
    }

    /// The first block from the one being read that is not on disk, completed (with what is already spoken of it)
    /// and kept. False when there is none.
    private func speakAheadToDisk(_ speaker: SentenceVoice, _ cache: VoiceCache, _ generation: Int) -> Bool {
        let blocks = VoiceCache.blockCount(sentences.count)
        let first = lock.locked { VoiceCache.block(of: feeding) }
        guard let block = (first..<max(first, blocks)).first(where: { !cache.has($0) }) else { return false }
        let start = block * VoiceCache.blockSize
        var parts: [[Float]] = []
        for i in 0..<min(VoiceCache.blockSize, sentences.count - start) {
            let (interrupted, done): (Bool, [Float]?) = lock.locked {
                // Back to the sentences being read as soon as they are wanted.
                let interrupted = closed || generation != self.generation || pendingID != nil
                    || nextMissing((speaker.keepsSpoken ? keptAhead : ahead) / 2) != nil
                return (interrupted, building[block]?[i] ?? nil)
            }
            if interrupted { return true }
            guard let spoken = done ?? speak(speaker, start + i) else { return true }
            parts.append(spoken)
        }
        let current: Bool = lock.locked {
            guard generation == self.generation else { return false }
            building[block] = nil
            return true
        }
        if current { keep(cache, block, parts) }
        return true
    }

    private func keep(_ cache: VoiceCache, _ block: Int, _ sentences: [[Float]]) {
        do {
            try cache.save(block, sentences: sentences, sampleRate: sampleRate)
        } catch {
            lock.locked { failure = error }
        }
    }

    private func cacheFor(_ voice: SentenceVoice) -> VoiceCache? {
        guard voice.keepsSpoken, let cacheDirectory else { return nil }
        return VoiceCache(text: text, voiceID: voice.id, directory: cacheDirectory)
    }
}

/// An event a thread waits on, like .NET's AutoResetEvent.
final class Wake: @unchecked Sendable {
    private let condition = NSCondition()
    private var set = false

    func signal() {
        condition.lock()
        set = true
        condition.signal()
        condition.unlock()
    }

    func wait(seconds: TimeInterval) {
        condition.lock()
        if !set { _ = condition.wait(until: Date().addingTimeInterval(seconds)) }
        set = false
        condition.unlock()
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
