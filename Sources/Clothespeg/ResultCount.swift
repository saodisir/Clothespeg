import Foundation

/// How long a reading is, in the unit its own script uses.
///
/// `String.count` counts grapheme clusters, spaces and punctuation included:
/// "The quick brown fox" is 19 characters but four words. A bar that says
/// "19 characters" over an English sentence answers a question nobody asked.
///
/// Chinese, Japanese, Korean and the South-East Asian scripts have no spaces
/// between words. There the character *is* the unit — Japanese counts 文字数,
/// and counting words would need a morphological analyser to mean anything —
/// so those stay on characters. Everything written with spaces between words
/// (English, Spanish, French, German, Russian, Arabic, …) counts words.
///
/// The split is by script, not by a list of languages: a language missing from
/// the list still lands on the right side, and a Chinese sentence carrying one
/// Latin product name is still Chinese.
enum ResultCount {
    /// A fifth of the letters is the same measure `SourceLanguage` uses to say
    /// a short text is Chinese rather than undecided.
    private static let share = 0.2

    static func label(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !unspaced(trimmed) else {
            return "\(trimmed.count) \(L("characters"))"
        }
        let count = words(in: trimmed)
        // A row of punctuation has no words to speak of; characters is the
        // honest answer there rather than "0 words".
        guard count > 0 else { return "\(trimmed.count) \(L("characters"))" }
        return "\(count) \(L("words"))"
    }

    /// Whitespace-separated pieces carrying at least one letter or digit.
    /// Punctuation on its own is not a word, and "¿cómo" and "estás?" each are.
    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { piece in
            piece.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }.count
    }

    /// Whether most letters come from scripts written without spaces between
    /// words. Pure arithmetic, so the self-test can ask it without a window.
    static func unspaced(_ text: String) -> Bool {
        var letters = 0
        var fromUnspaced = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if isUnspacedScript(scalar) { fromUnspaced += 1 }
        }
        return letters > 0 && Double(fromUnspaced) / Double(letters) >= share
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3040...0x30FF).contains(v)   // kana
            || (0x3400...0x4DBF).contains(v)   // Han, extension A
            || (0x4E00...0x9FFF).contains(v)   // Han, unified
            || (0xAC00...0xD7A3).contains(v)   // Hangul syllables
            || (0x1100...0x11FF).contains(v)   // Hangul jamo
            || (0x0E00...0x0E7F).contains(v)   // Thai
            || (0x0E80...0x0EFF).contains(v)   // Lao
            || (0x1000...0x109F).contains(v)   // Myanmar
            || (0x1780...0x17FF).contains(v)   // Khmer
    }
}
