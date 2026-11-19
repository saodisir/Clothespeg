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

    // MARK: Script conversion

    /// The writing system a piece of text is in, in the coarse terms a
    /// translation's success can be judged by.
    enum Writing: Equatable {
        case han, kana, hangul, latin, other

        static func of(_ text: String) -> Writing {
            var counts: [Writing: Int] = [:]
            for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
                counts[of(scalar), default: 0] += 1
            }
            return counts.max { $0.value < $1.value }?.key ?? .other
        }

        static func of(_ language: Locale.Language?) -> Writing {
            switch language?.languageCode?.identifier ?? "" {
            case "zh": return .han
            case "ja": return .kana
            case "ko": return .hangul
            case "": return .other
            default: return .latin
            }
        }

        private static func of(_ scalar: Unicode.Scalar) -> Writing {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { return .han }
            if (0x3040...0x30FF).contains(v) { return .kana }
            if (0xAC00...0xD7A3).contains(v) { return .hangul }
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || (0x00C0...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v) { return .latin }
            return .other
        }

        /// Whether any letter in the text is written in this system.
        ///
        /// Different from `of(_:)`, which reports only the *dominant* script.
        /// A Chinese answer told to keep product names, URLs and code can be
        /// mostly Latin by letter count and still be a translation — measured
        /// 2026-11-16, 32 Han against 56 Latin in one answer.
        static func appears(in text: String, _ writing: Writing) -> Bool {
            guard writing != .other else { return false }
            return text.unicodeScalars.contains {
                CharacterSet.letters.contains($0) && of($0) == writing
            }
        }
    }

    /// Whether an answer is still written the way the input was, when the target
    /// asked for a different writing system.
    ///
    /// The byte test (`answer == input`) is not enough, and that is measured:
    /// on 2026-11-13 a model asked for 繁體 handed back 简体 with one character
    /// moved, so the two strings differed, the app called it a translation and
    /// painted it. Script is the honest question — if the input is Latin and the
    /// target is Chinese, an answer that is still Latin translated nothing.
    ///
    /// Only writes that cannot be confused with each other are judged. Two
    /// Latin languages are not: English asked for French comes back Latin
    /// whatever happened, so the script says nothing there. Han against kana is
    /// not either, because Japanese is written with both. Everything else is a
    /// real answer — Chinese asked for English that is still Chinese did not
    /// translate, and neither did Korean asked for Chinese.
    static func untouched(_ answer: String, since text: String, into target: Locale.Language?) -> Bool {
        let source = Writing.of(text)
        let out = Writing.of(answer)
        let want = Writing.of(target)
        guard out == source, want != source else { return false }
        // A translation is allowed to keep the source script for product
        // names, URLs and code — rule 3 of the prompt asks for exactly that.
        // What it cannot do is contain *none* of the script that was asked
        // for. 2026-11-16: a good Chinese answer full of InputTables /
        // SuperTables / WriteBackExtreme was read as Latin by `of(_:)`, and
        // the bar called it untranslated.
        if Writing.appears(in: answer, want) { return false }
        if (source == .han && want == .kana) || (source == .kana && want == .han) {
            return false
        }
        return true
    }
}

/// Simplified ↔ Traditional, converted here rather than by a language model.
///
/// This is a script conversion, not a translation: every character has a
/// counterpart, the answer is exact, and ICU has been doing it on this Mac for
/// twenty years. Sending it to a 7B model is how 「译成繁體」 came back 简体 —
/// measured twice on 2026-11-13, once in place and once on the card — because to
/// a model that reads both scripts the words already are in the language asked
/// for.
///
/// It is also free: no key, no wire, no wait. The card path skips the engine
/// entirely for this pair.
enum ScriptConversion {
    private static let toTraditional = StringTransform("Hans-Hant")
    private static let toSimplified = StringTransform("Hant-Hans")

    /// The text in the other script, or nil when this is not that pair.
    static func convert(_ text: String, from source: Locale.Language?,
                        to target: Locale.Language) -> String? {
        guard source?.languageCode?.identifier == "zh",
              target.languageCode?.identifier == "zh" else { return nil }
        let from = source?.script?.identifier
        let into = target.script?.identifier
        let transform: StringTransform
        switch (from, into) {
        case ("Hans", "Hant"): transform = toTraditional
        case ("Hant", "Hans"): transform = toSimplified
        default: return nil
        }
        return text.applyingTransform(transform, reverse: false)
    }

    static func convert(_ texts: [String], from source: Locale.Language?,
                        to target: Locale.Language) -> [String]? {
        guard let first = texts.first, convert(first, from: source, to: target) != nil else {
            return nil
        }
        return texts.map { convert($0, from: source, to: target) ?? $0 }
    }
}
