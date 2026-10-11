// Text to Kokoro's phonemes, as kokoro.js does it: punctuation is kept out of the phonemizer and given to the model as
// it is, and eSpeak NG's IPA is adjusted to the phonemes Kokoro was trained on. The same as KokoroEngine.Phonemize and
// FixPhonemes in C#. Plain Foundation (NSRegularExpression, for the look-behinds), so it is there with or without the
// Kokoro trait.
import Foundation
import SpeechwarpVoice

enum KokoroPhonemes {
    /// Between sentences: after ".", "!", "?" or "…" and white space, or at a blank line.
    private static let sentenceEnd = regex(#"(?<=[.!?…])\s+|\n{2,}"#)
    /// A run of punctuation with the white space around it.
    private static let punctuation = regex(#"(\s*[;:,.!?¡¿—…"«»“”(){}\[\]]+\s*)+"#)
    private static let hundred = regex(#"(?<=[a-zɹː])(?=hˈʌndɹɪd)"#)
    private static let loneZ = regex(#" z(?=[;:,.!?¡¿—…"«»“” ]|$)"#)
    private static let ninety = regex(#"(?<=nˈaɪn)ti(?!ː)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants: a failure here is a bug in this file.
        try! NSRegularExpression(pattern: pattern)
    }

    /// `text` cut between sentences, as the engine gives them to the model.
    static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        for match in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            last = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: last))
        return pieces
    }

    /// The phonemes the model is given for `text`: the phonemizer's IPA between the punctuation, which is kept,
    /// adjusted as kokoro.js does.
    static func phonemize(_ text: String, language: String, phonemizer: Phonemizer) throws -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in punctuation.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > last {
                result += try phonemizer.phonemize(
                    ns.substring(with: NSRange(location: last, length: match.range.location - last)), language: language)
            }
            result += ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        if last < ns.length {
            result += try phonemizer.phonemize(ns.substring(from: last), language: language)
        }
        return fix(result, language: language)
    }

    /// kokoro.js's adjustments to eSpeak's IPA, for the phonemes Kokoro was trained on.
    static func fix(_ phonemes: String, language: String) -> String {
        // Ordinal replacements, as in C#: character by character, never as composed characters.
        var ps = phonemes
        for (from, to) in [("kəkˈoːɹoʊ", "kˈoʊkəɹoʊ"),
                           ("kəkˈɔːɹoʊ", "kˈoʊkəɹoʊ"), // eSpeak NG 1.52's American "Kokoro"
                           ("kəkˈɔːɹəʊ", "kˈəʊkəɹəʊ"),
                           ("ʲ", "j"), ("r", "ɹ"), ("x", "k"), ("ɬ", "l")] {
            ps = ps.replacingOccurrences(of: from, with: to, options: .literal)
        }
        ps = replace(hundred, in: ps, with: " ")
        ps = replace(loneZ, in: ps, with: "z")
        if language == "en-us" {
            ps = replace(ninety, in: ps, with: "di")
        }
        return trim(ps)
    }

    /// Without white space at either end, as C#'s Trim.
    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: template)
    }
}
