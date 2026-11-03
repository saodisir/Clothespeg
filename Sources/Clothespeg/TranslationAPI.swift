import Foundation
import Security

/// Translation done by a model on the other end of a wire.
///
/// The system's own translator (see `Translator`) runs on this Mac, needs no
/// key, and never sends the words anywhere — which is why it is what the app
/// falls back to. It is also, on the pair this was written for, not very
/// good: it translates words rather than sentences, and a page of release
/// notes comes back as one.
///
/// So there is a second engine, and it is chosen by the presence of a key
/// rather than by a switch: a key that is filled in is a person saying "use
/// this". Empty it and the system's engine answers again. One field, one
/// meaning, nothing to keep in step.
///
/// The endpoint is configurable all the way down — address, model, key — so
/// the free model of the month can be swapped for another, or for another
/// provider whose API is shaped like this one (which most are: this is the
/// `/chat/completions` shape OpenAI settled on).
enum TranslationAPI {
    /// SiliconFlow's own address, and the free model that was measured for
    /// this feature: 1.2 s for a short line, 2.9 s for a screenful of
    /// mixed-language notes, 32K of context, ¥0 for both directions.
    static let defaultEndpoint = "https://api.siliconflow.cn/v1/chat/completions"
    static let defaultModel = "Qwen/Qwen2.5-7B-Instruct"

    /// Text past this many characters is cut before it is sent. The model
    /// holds 32K tokens, and a capture never legitimately holds more than a
    /// screenful; the cut exists so a stray full-page selection cannot turn
    /// into a request that is billed for and refused.
    static let limit = 16_000

    private static let modelKey = "translationModel"
    private static let endpointKey = "translationEndpoint"

    // MARK: Settings

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultModel : stored
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      forKey: modelKey)
        }
    }

    static var endpoint: String {
        get {
            let stored = UserDefaults.standard.string(forKey: endpointKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultEndpoint : stored
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      forKey: endpointKey)
        }
    }

    /// The key itself, in the login keychain rather than in a preferences file.
    ///
    /// A preference file is copied by every backup tool, synced by some of
    /// them, and readable by anything that can read `~/Library/Preferences`.
    /// A credential belongs in the one place the system keeps credentials.
    static var key: String {
        get { KeyVault.read() ?? "" }
        set {
            guard !KeyVault.write(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            diagLog("Translation: the keychain refused the key — left unchanged")
        }
    }

    /// Whether a key has been filled in — which is the whole of the choice
    /// between the two engines.
    static var isConfigured: Bool { !key.isEmpty }

    // MARK: Asking

    /// What went wrong, in the words the bar or the settings page will use.
    enum Failure: LocalizedError {
        /// The endpoint is not a URL at all.
        case badEndpoint(String)
        /// 401 or 403: the key is wrong, or has been revoked.
        case rejected(String)
        /// 429: too many requests, or the day's free quota is spent.
        case rateLimited(String)
        /// Anything else the server said no to.
        case http(Int, String)
        /// No answer at all — offline, DNS, timeout.
        case transport(String)
        /// A 200 with nothing in it. Worth its own case: it reads as "the
        /// translation is empty", and that is a different bug from a refusal.
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .badEndpoint(let address):
                return "Address is not a URL: \(address)"
            case .rejected(let detail):
                return "Key refused: \(detail)"
            case .rateLimited(let detail):
                return "Too many requests: \(detail)"
            case .http(let code, let detail):
                return "HTTP \(code): \(detail)"
            case .transport(let detail):
                return "No answer: \(detail)"
            case .emptyAnswer:
                return "The model answered with nothing"
            }
        }
    }

    /// The words, in the language asked for.
    ///
    /// The source language is never named: a model reads the text and a
    /// target, which is the one thing it is reliably good at, and naming a
    /// source it may have got wrong would be handing it a mistake.
    static func translate(_ text: String, into language: Locale.Language) async throws -> String {
        let answer = try await call(text: text, system: prompt(into: language))
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyAnswer }
        return trimmed
    }

    /// One short round trip, for the Test button: does the address answer,
    /// does the key work, does the model exist. The three faults people
    /// actually hit, each with its own sentence — a single "failed" would
    /// leave the next step to guesswork.
    static func test() async -> (ok: Bool, detail: String) {
        guard isConfigured else { return (false, "No key yet.") }
        let began = Date()
        do {
            let answer = try await call(text: "The line is where things rest.",
                                        system: prompt(into: Locale.Language(identifier: "zh-Hans")),
                                        maxTokens: 80)
            let took = Int(Date().timeIntervalSince(began) * 1000)
            let said = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, "\(model) · \(took) ms · \(said)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: The request

    private static func call(text: String, system: String,
                             maxTokens: Int = 4096) async throws -> String {
        let address = endpoint
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            throw Failure.badEndpoint(address)
        }
        let credential = key
        guard !credential.isEmpty else { throw Failure.rejected("no key") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A capture waits behind this: the bar says 翻译中… for as long as it
        // runs, so a slow answer has to end in a sentence rather than in a
        // spinner that never stops. The measurement was 1–3 s; 30 leaves room
        // for a cold model without leaving the bar waiting for ever.
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            // Low but not zero: at 0 a 7B model occasionally repeats a line,
            // and a translation that loops is worse than one that varies.
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": String(text.prefix(limit))],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Both shapes are in the wild: this provider's `{"code":30014,
            // "message":"Token is invalid."}` and OpenAI's own `{"error":
            // {"message":…}}`. Read whichever is there rather than print raw
            // JSON into a settings row.
            let said = message(in: data) ?? "no detail"
            switch status {
            case 401, 403: throw Failure.rejected(said)
            case 429: throw Failure.rateLimited(said)
            default: throw Failure.http(status, said)
            }
        }

        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let content = answer.choices.first?.message.content else {
            throw Failure.emptyAnswer
        }
        return content
    }

    /// The human-readable half of an error body, from either shape.
    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let said = object["message"] as? String { return said }
        if let code = object["code"] as? Int { return "code \(code)" }
        if let error = object["error"] as? [String: Any],
           let said = error["message"] as? String { return said }
        return nil
    }

    private struct Answer: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    // MARK: The prompt

    /// What the model is told, and why each line is there.
    ///
    /// A 7B model follows a list of rules far more reliably than it follows
    /// one sentence of encouragement, so the rules are numbered and blunt.
    /// "No preface" earns its place: the same model without it answers
    /// usefully and then adds 翻译如下： in front, which lands in the capture
    /// as part of the translation and into the pasteboard as something the
    /// person has to delete.
    private static func prompt(into language: Locale.Language) -> String {
        """
        You are a translation engine. Translate the text the user sends into \(name(of: language)).

        Rules:
        1. Reply with the translation only. No preface, no explanation, no quotation marks, no notes about yourself.
        2. Keep the original line breaks, numbering and order.
        3. Leave code, URLs, file names, product names and version numbers exactly as they are.
        4. Translate everything. Do not summarise, shorten, or add anything that is not in the text.
        """
    }

    /// The language's name as its own readers write it.
    ///
    /// Written here rather than asked of `Locale`, because the name has to be
    /// unambiguous to the model: "Chinese" leaves it to choose between two
    /// scripts, while 简体中文 does not. The fallback is the identifier
    /// itself, which a model reads correctly often enough — and which only
    /// shows up for a target the settings cannot produce today.
    static func name(of language: Locale.Language) -> String {
        let id = language.minimalIdentifier.lowercased()
        if let exact = names[id] { return exact }
        if let base = id.split(separator: "-").first, let name = names[String(base)] { return name }
        return id
    }

    private static let names: [String: String] = [
        "en": "English",
        "zh-hans": "简体中文",
        "zh-hant": "繁體中文",
        "zh": "中文",
        "ja": "日本語",
        "ko": "한국어",
        "fr": "Français",
        "de": "Deutsch",
        "es": "Español",
        "pt": "Português",
        "it": "Italiano",
        "ru": "Русский",
        "ar": "العربية",
        "th": "ไทย",
        "vi": "Tiếng Việt",
        "nl": "Nederlands",
        "id": "Bahasa Indonesia",
        "tr": "Türkçe",
    ]
}

// MARK: - Probe

/// The two things about the other end of the wire that this repo cannot read
/// off the code: whether the keychain accepts and returns a key from *this*
/// binary, and whether the address answers. Run one with
/// `CLOTHESPEG_TRANSLATE_API_PROBE=<path>` and, to ask the address as well,
/// `CLOTHESPEG_TRANSLATE_KEY=<key>`; ordinary runs never set either.
///
/// The keychain leg is the one that fails quietly: a build signed ad hoc
/// writes the item and then cannot read it back, so the settings page shows a
/// key that is gone at the next launch, with nothing on screen to say why.
enum TranslateAPIProbe {
    @MainActor
    static func run(handedIn: String?, keep: Bool = false) -> String {
        var lines = ["translate api probe:"]

        let before = TranslationAPI.key
        let marker = "probe-\(UUID().uuidString)"
        TranslationAPI.key = marker
        let back = TranslationAPI.key
        lines.append("keychain write then read: "
            + (back == marker ? "ok" : "FAILED — got \(back.isEmpty ? "nothing" : "something else")"))
        // Put back whatever was there. The probe runs in the same app as the
        // settings, and it must not be the reason a working key disappeared.
        TranslationAPI.key = before
        lines.append("previous key restored: \(TranslationAPI.key == before ? "yes" : "no")")

        guard let key = handedIn, !key.isEmpty else {
            lines.append("no CLOTHESPEG_TRANSLATE_KEY given — the address was not asked")
            return lines.joined(separator: "\n")
        }
        TranslationAPI.key = key
        lines.append("model \(TranslationAPI.model)")
        lines.append("address \(TranslationAPI.endpoint)")

        let box = Box()
        Task {
            let outcome = await TranslationAPI.test()
            box.text = (outcome.ok ? "ok · " : "failed · ") + outcome.detail
            box.done = true
        }
        let deadline = Date().addingTimeInterval(40)
        while !box.done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        lines.append("test: " + (box.done ? box.text : "no answer in 40 s"))
        // `CLOTHESPEG_TRANSLATE_KEEP` leaves the key in the keychain, which is
        // how a fresh machine gets one without it being typed into the window:
        // a key pasted into a terminal is a key in a shell history.
        if keep {
            lines.append("key left in the keychain: yes")
        } else {
            TranslationAPI.key = before
        }
        return lines.joined(separator: "\n")
    }

    /// Written from the task, read once the run loop has been pumped.
    private final class Box: @unchecked Sendable {
        var text = ""
        var done = false
    }
}


// MARK: - The keychain

/// One generic password, kept where the system keeps passwords.
///
/// Small on purpose: one service, one account, read and write and nothing
/// else. `SecItemAdd` answers `errSecDuplicateItem` on the second write of the
/// same pair, which is why the write is an update when something is already
/// there rather than an add that would fail the second time a key is edited.
private enum KeyVault {
    private static let service = "com.vizwise.clothespeg.translation"
    private static let account = "apiKey"

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Writes the key, or deletes it when handed an empty string — clearing
    /// the field is how the system's engine is chosen again, and a deleted
    /// item is the honest record of that.
    static func write(_ value: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        if read() != nil {
            let attributes: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(insert as CFDictionary, nil)
        // A build without a stable signature cannot read the keychain back
        // (errSecMissingEntitlement, -34018). Say so rather than leave a key
        // that was accepted on screen and is gone on the next launch.
        if status != errSecSuccess {
            diagLog("Translation: keychain write failed — OSStatus \(status)")
        }
        return status == errSecSuccess
    }
}
