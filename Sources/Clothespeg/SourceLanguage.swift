import Foundation
import NaturalLanguage

/// Which language those words are in — decided here rather than asked for.
///
/// The system's translation engine will work this out by itself when it is given
/// no source, and when it cannot, it puts up a sheet of its own —「无法自动检测
/// 语言。请选择要翻译的语言。」— and *waits*. From the outside that is a capture
/// that says 翻译中… for ever, which is exactly what it was reported as.
///
/// Text read off a screen is the case it misjudges most often: a line of
/// interface, a column of numbers, two languages in one paragraph, a word or
/// two. So the source is decided before the engine is asked, the way EasyDict
/// does it (`AppleLanguageDetector`), and the engine is never left to guess.
///
/// `nil` means "could not tell" — an answer, not a failure. It is said on the
/// bar rather than turned into a wrong translation.
enum SourceLanguage {
    /// The language those words are in, or nil when there is no telling.
    ///
    /// Short text is where the model falls apart — EasyDict carries a whole
    /// post-processing pass for the same reason, because `NLLanguageRecognizer`
    /// reads "apple" as Turkish and "DeepSeek" as Dutch. So scripts decide
    /// first and the model is only asked about what the scripts cannot settle:
    /// one Chinese character in an eight-character selection *is* Chinese, and
    /// a handful of Latin letters is one of the Latin languages — whichever the
    /// model names when it is at all sure, English when it is not.
    static func guess(_ text: String) -> Locale.Language? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let total = Double(trimmed.count)
        let short = trimmed.count <= 12
        let scalars = trimmed.unicodeScalars

        // Kana first, because Japanese is written with Chinese characters too:
        // a Han-character rule that ran first would call every Japanese page
        // Chinese. Any kana at all is enough to say Japanese — Han text never
        // contains it.
        let kana = scalars.filter { (0x3040...0x30FF).contains($0.value) }.count
        if kana > 0 {
            return Locale.Language(identifier: "ja")
        }

        let hangul = scalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        if hangul > 0, short || Double(hangul) / total >= 0.2 {
            return Locale.Language(identifier: "ko")
        }

        // Han characters are a script rather than a guess. A real share of a
        // long text is Chinese; in a short one a single character is already
        // the whole answer, and demanding a fifth of eight characters is how a
        // selection like "v1.2.3版" ends up with no language at all.
        let han = scalars.filter { isHan($0) }.count
        if han > 0, short || Double(han) / total >= 0.2 {
            return Locale.Language(identifier: mostlySimplified(trimmed) ? "zh-Hans" : "zh-Hant")
        }

        let (dominant, confidence) = recognise(trimmed)

        // Short and Latin: the model's answer is worth having when it is sure —
        // "Bonjour" is French — and worthless when it is not, where English is
        // the better bet than nothing at all.
        if short {
            if let dominant, confidence >= 0.4 {
                return Locale.Language(identifier: dominant.rawValue)
            }
            return isMostlyLatin(trimmed) ? Locale.Language(identifier: "en") : nil
        }

        guard let dominant, confidence >= 0.4 else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    private static func recognise(_ text: String) -> (NLLanguage?, Double) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        guard !hypotheses.isEmpty else { return (nil, 0) }
        // A thumb on the scale for English, and a small one.
        //
        // Product names and single words are what this app is pointed at, and
        // the model reads them as everything but English: "DeepSeek" comes back
        // Dutch, "apple" Turkish. EasyDict solves the same problem the same way
        // — a weighted boost for the reader's languages — and this is the one
        // part of its detector worth copying outright. Fifteen hundredths does
        // not move a real answer: French at 0.9 stays French.
        var best = (NLLanguage.undetermined, 0.0)
        for (language, probability) in hypotheses {
            let score = probability + (language == .english ? 0.15 : 0)
            if score > best.1 { best = (language, score) }
        }
        return (best.0, best.1)
    }

    /// Latin letters, accents allowed.
    ///
    /// `café` and `naïve` are Latin as much as `cafe` is, and a rule that
    /// demanded ASCII would refuse to name either. Cyrillic, Greek and the rest
    /// stay out — those are their own scripts and the model handles them.
    private static func isMostlyLatin(_ text: String) -> Bool {
        var letters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            let value = scalar.value
            let ascii = (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
            let latin = (0x00C0...0x024F).contains(value) || (0x1E00...0x1EFF).contains(value)
            if !ascii, !latin { return false }
        }
        return letters > 0
    }

    /// Whether two languages are the same language for this purpose.
    ///
    /// `zh-Hans` and `zh-Hant` are not: the scripts differ, and asking the
    /// engine to move between them is a request it may refuse rather than a
    /// question already answered. `en-US` and `en-GB` are.
    static func same(_ a: Locale.Language?, _ b: Locale.Language?) -> Bool {
        guard let a, let b,
              let left = a.languageCode?.identifier,
              let right = b.languageCode?.identifier else { return false }
        guard left == right else { return false }
        guard let leftScript = a.script?.identifier,
              let rightScript = b.script?.identifier else { return true }
        return leftScript == rightScript
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)      // unified ideographs
            || (0x3400...0x4DBF).contains(scalar.value) // extension A
    }

    /// Simplified or traditional, by counting what would change.
    ///
    /// The same measure EasyDict uses (a ratio rather than one character): a
    /// simplified page carrying a handful of traditional characters is still a
    /// simplified page, and one character is not evidence.
    /// The ICU transform behind simplified/traditional conversion. Named by its
    /// ICU id because Foundation has no constant for this one — `StringTransform`
    /// only ships `toLatin`, `toLatinASCII` and the like.
    private static let toSimplified = StringTransform("Traditional-Simplified")

    private static func mostlySimplified(_ text: String) -> Bool {
        guard let simplified = text.applyingTransform(toSimplified, reverse: false),
              simplified.count == text.count else { return true }
        var han = 0
        var traditional = 0
        for (asIs, changed) in zip(text, simplified) where isHan(asIs.unicodeScalars.first ?? " ") {
            han += 1
            if asIs != changed { traditional += 1 }
        }
        guard han > 0 else { return true }
        return Double(traditional) / Double(han) < 0.15
    }
}
