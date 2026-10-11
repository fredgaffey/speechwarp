#if canImport(AVFoundation) && canImport(CryptoKit)
import AVFoundation
import CryptoKit
import Foundation

/// Sentences a slow voice (one whose `keepsSpoken` is true, such as Kokoro) has already spoken, kept on disk so
/// that they need not be spoken again. The same layout as the C# `VoiceCache`.
///
/// The sentences of a text (as `SpokenText` cuts it) are kept in blocks of `blockSize`: each block is an AAC
/// file (32 kbit/s, mono, at the voice's rate) with the length of each sentence in a small JSON file beside it,
/// which is written last, so a block is there only once both are. About 150 MB for a ten-hour book.
///
/// Each text and voice has a folder of its own: `directory/TEXT/VOICE/`, where TEXT is the first 16 hex digits of
/// the SHA-256 of the text (UTF-8) and VOICE is the voice id with characters a file name cannot hold replaced by
/// "-". The default directory, `defaultDirectory`, is under Library/Caches, which the system may clear when space
/// runs short; a block that has gone, or cannot be read, is simply spoken again.
public final class VoiceCache: @unchecked Sendable {
    /// Sentences in a block.
    public static let blockSize = 40

    /// Library/Caches/speechwarp-voice, the default place for every text and voice.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speechwarp-voice", isDirectory: true)
    }

    /// The folder kept for this text and voice.
    public let directory: URL
    /// The voice id the sentences are kept for.
    public let voiceID: String

    private static let bitRate = 32000

    /// The cache of `text` spoken by the voice `voiceID`, under `directory` (default `defaultDirectory`).
    /// Nothing is created until a block is saved.
    public init(text: String, voiceID: String, directory: URL? = nil) {
        self.voiceID = voiceID
        self.directory = (directory ?? Self.defaultDirectory)
            .appendingPathComponent(Self.textKey(text), isDirectory: true)
            .appendingPathComponent(Self.fileName(voiceID), isDirectory: true)
    }

    /// The folder name for a text: the first 16 hex digits of its SHA-256.
    public static func textKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The block holding sentence `sentence`.
    public static func block(of sentence: Int) -> Int { sentence / blockSize }

    /// The number of blocks for `sentences` sentences.
    public static func blockCount(_ sentences: Int) -> Int { (sentences + blockSize - 1) / blockSize }

    private func audioURL(_ block: Int) -> URL { directory.appendingPathComponent(String(format: "%05d.m4a", block)) }
    private func lengthsURL(_ block: Int) -> URL { directory.appendingPathComponent(String(format: "%05d.json", block)) }

    /// Whether block `block` is kept.
    public func has(_ block: Int) -> Bool {
        FileManager.default.fileExists(atPath: lengthsURL(block).path)
            && FileManager.default.fileExists(atPath: audioURL(block).path)
    }

    /// Block `block`'s sentences, converted to `sampleRate`; nil if it is not kept or cannot be read (then it is
    /// deleted, to be spoken again).
    public func load(_ block: Int, sampleRate: Int) -> [[Float]]? {
        guard has(block) else { return nil }
        do {
            let lengths = try JSONDecoder().decode([Int].self, from: Data(contentsOf: lengthsURL(block)))
            let file = try AVAudioFile(forReading: audioURL(block), commonFormat: .pcmFormatFloat32, interleaved: false)
            let rate = Int(file.processingFormat.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(max(1, file.length))) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if file.length > 0 { try file.read(into: buffer) }
            let all = AudioSamples.mono(buffer)
            var at = 0
            return lengths.map { length in
                let take = min(max(length, 0), all.count - at)
                defer { at += take }
                return Resampling.linear(all[at..<at + take], from: rate, to: sampleRate)
            }
        } catch {
            remove(block)
            return nil
        }
    }

    /// Keeps block `block`'s sentences, spoken at `sampleRate` (one array for each sentence of the block, empty for
    /// one with nothing to say).
    public func save(_ block: Int, sentences: [[Float]], sampleRate: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(String(format: "%05d.", block) + UUID().uuidString + ".part.m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(sentences.flatMap { $0 }, to: temp, sampleRate: sampleRate)
        try? FileManager.default.removeItem(at: audioURL(block))
        try FileManager.default.moveItem(at: temp, to: audioURL(block))
        try JSONEncoder().encode(sentences.map(\.count)).write(to: lengthsURL(block), options: .atomic)
    }

    /// Forgets block `block`.
    public func remove(_ block: Int) {
        try? FileManager.default.removeItem(at: lengthsURL(block))
        try? FileManager.default.removeItem(at: audioURL(block))
    }

    /// Forgets every block of this text in this voice.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes AAC; the file is closed when this returns.
    private func write(_ samples: [Float], to url: URL, sampleRate: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        if let buffer = AudioSamples.buffer(samples, sampleRate: sampleRate) {
            try file.write(from: buffer)
        }
    }

    /// A voice id as a folder name: letters, digits, ".", "_" and "-" kept, anything else "-" (and a leading ".").
    private static func fileName(_ voiceID: String) -> String {
        var name = String(voiceID.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return scalar.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "-"
        })
        if name.hasPrefix(".") { name = "-" + name.dropFirst() }
        return name
    }
}
#endif
