// How fast Kokoro speaks on this device. The same as Speechwarp.Voice.Kokoro's KokoroBenchmark in C#.
#if Kokoro && canImport(OnnxRuntimeBindings)
import Foundation
import SpeechwarpVoice

/// What `KokoroBenchmark.run` measured.
public struct KokoroBenchmarkResult: Equatable, Sendable {
    /// How many engines spoke at once.
    public let engines: Int
    /// Paragraphs spoken.
    public let paragraphs: Int
    /// Seconds of audio produced.
    public let audioSeconds: Double
    /// Seconds it took, after loading.
    public let elapsedSeconds: Double
    /// Seconds the first engine took to load the model.
    public let loadSeconds: Double

    /// Seconds of work for each second of audio: below 1 is faster than listening.
    public var realTimeFactor: Double { audioSeconds > 0 ? elapsedSeconds / audioSeconds : .infinity }

    /// Seconds of audio for each second of work, the inverse: above 1 is faster than listening.
    public var timesRealTime: Double { elapsedSeconds > 0 ? audioSeconds / elapsedSeconds : 0 }
}

/// How fast Kokoro speaks on this device: speaks paragraphs of a text for a while and measures the audio produced.
/// Nothing is played. Run it on the device that matters (a phone is several times slower than a Mac).
public enum KokoroBenchmark {
    /// Speaks the paragraphs of `text` (separated by blank lines), in order, until they run out or `duration` seconds
    /// have passed, with `parallel` engines speaking different paragraphs at once (to see whether running several
    /// helps). A paragraph under way is finished. Blocks the calling thread.
    ///
    /// - Parameters:
    ///   - directory: The model directory.
    ///   - phonemizer: Turns words into IPA; it must be safe to call from several threads if `parallel` is above 1.
    ///   - text: What to speak.
    ///   - voice: The voice, `KokoroModels.defaultVoice` unless given.
    ///   - modelFile: The model each engine loads.
    ///   - threads: CPU threads for each engine; 0 for one a core.
    ///   - duration: How long to keep going, in seconds: 60 unless given.
    ///   - parallel: Engines speaking at once, 1 or more.
    public static func run(directory: String, phonemizer: Phonemizer, text: String,
                           voice: String = KokoroModels.defaultVoice,
                           modelFile: String = KokoroModels.defaultModelFile, threads: Int = 0,
                           duration: TimeInterval = 60, parallel: Int = 1) throws -> KokoroBenchmarkResult {
        precondition(parallel >= 1, "parallel must be 1 or more")
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map(KokoroPhonemes.trim).filter { !$0.isEmpty }

        var start = Date()
        var engines = [try KokoroEngine(directory: directory, phonemizer: phonemizer, modelFile: modelFile,
                                        threads: threads)]
        let load = Date().timeIntervalSince(start)
        defer { engines.forEach { $0.close() } }
        for _ in 1..<parallel {
            engines.append(try KokoroEngine(directory: directory, phonemizer: phonemizer, modelFile: modelFile,
                                            threads: threads))
        }

        let lock = NSLock()
        var next = 0, spoken = 0, frames = 0
        var failure: Error?
        start = Date()
        let began = start
        DispatchQueue.concurrentPerform(iterations: parallel) { worker in
            while Date().timeIntervalSince(began) < duration {
                lock.lock()
                let index = next
                next += 1
                let stop = failure != nil
                lock.unlock()
                if stop || index >= paragraphs.count { break }
                do {
                    let count = try engines[worker].speak(paragraphs[index], voice: voice).count
                    lock.lock()
                    frames += count
                    spoken += 1
                    lock.unlock()
                } catch {
                    lock.lock()
                    failure = failure ?? error
                    lock.unlock()
                    break
                }
            }
        }
        if let failure { throw failure }
        return KokoroBenchmarkResult(engines: parallel, paragraphs: spoken,
                                     audioSeconds: Double(frames) / Double(KokoroEngine.sampleRate),
                                     elapsedSeconds: Date().timeIntervalSince(start), loadSeconds: load)
    }
}
#endif
