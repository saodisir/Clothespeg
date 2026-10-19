import Foundation
import UserNotifications

/// The reminder half of a note: what it says, when it rings, and the pipe
/// between the note and the system that rings it.
///
/// One file rather than methods scattered across the line, because the
/// reminder has three lives that must agree: the note's field, the system's
/// pending request, and the moment of ringing. Two of those living apart
/// from the third is how a reminder rings twice or never.
extension Note {

    /// When the reminder rings next, worked out for a repeating one.
    ///
    /// `remindAt` is where the reminder was set from; for a repeating one
    /// that moment is the *first* turn when it is still ahead — the day
    /// the picker was given is the day the reminder means, and the rule
    /// takes over from there. Once the anchor is behind — the usual state
    /// of an old note — the next matching moment is searched from now, and
    /// a one-time reminder rings where it was set, past or not.
    func reminderOccurrence(after now: Date = Date()) -> Date? {
        guard let at = remindAt else { return nil }
        guard let rule = remindRule else { return at }
        let calendar = Calendar.current
        var parts = DateComponents()
        parts.hour = calendar.component(.hour, from: at)
        parts.minute = calendar.component(.minute, from: at)
        switch rule {
        case .daily:
            break
        case .weekly:
            parts.weekday = calendar.component(.weekday, from: at)
        case .monthly:
            parts.day = calendar.component(.day, from: at)
        }
        let start = at > now ? at.addingTimeInterval(-1) : now
        return calendar.nextDate(after: start, matching: parts, matchingPolicy: .nextTime)
    }

    /// What the picker's header and the card's footer call the reminder,
    /// in the calendar's own words — "每周三 09:00", not ours to translate.
    /// Nil when there is no reminder to name.
    static func reminderSummary(at: Date?, rule: RepeatRule?) -> String? {
        guard let at else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        switch rule {
        case .daily:
            formatter.setLocalizedDateFormatFromTemplate("jm")
            return String(format: L("Every day %@"), formatter.string(from: at))
        case .weekly:
            formatter.setLocalizedDateFormatFromTemplate("E jm")
            return String(format: L("Every week %@"), formatter.string(from: at))
        case .monthly:
            formatter.setLocalizedDateFormatFromTemplate("d jm")
            return String(format: L("Every month %@"), formatter.string(from: at))
        case nil:
            formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
            return formatter.string(from: at)
        }
    }

    var reminderSummary: String? {
        // A repeating one names its next ring rather than its anchor, so a
        // weekly reminder whose anchor Monday has gone by reads Wednesday.
        Note.reminderSummary(at: reminderOccurrence(), rule: remindRule)
    }

    /// What the card's caption calls the reminder: when it next lands, and
    /// nothing else. A repeating one and a single one both have a next
    /// moment — the rule that produces it lives in the editor's panel, not
    /// here — and one that has rung its only ring reads 「提醒已到」 instead,
    /// which is the caption's word for finished.
    var reminderCaption: String? {
        guard let next = reminderOccurrence(),
              let nextText = Note.reminderSummary(at: next, rule: nil) else { return nil }
        return "\(L("Next")) \(nextText)"
    }
}

/// Schedules the notes' reminders and answers them when they ring.
///
/// The system keeps the pending list between launches — a request made once
/// rings every week without this app ever opening — so the work here is not
/// scheduling but *agreeing*: the pending list is made to match the notes
/// on every save, adding what is missing and dropping what is gone.
@MainActor
final class ReminderScheduler: NSObject {
    static let shared = ReminderScheduler()

    /// Posted when a reminder rings, with the note's id under "id". The
    /// line brings the rope down for it and marks the card.
    static let firedNotification = Notification.Name("app.clothespeg.noteReminderFired")

    private override init() { super.init() }

    /// Hands the delegate over, once, at launch. The app is always running
    /// — it is the rope — so delivery arrives here in person, and a banner
    /// draws only because `willPresent` asks for it.
    ///
    /// The authorization state is said out loud here, because the second
    /// round of testing lost a day to it: a schedule that succeeds while
    /// the system is told not to deliver is a reminder that silently
    /// becomes the overdue fallback, a minute late and without a banner.
    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            let status: String = {
                switch settings.authorizationStatus {
                case .notDetermined: return "notDetermined"
                case .denied: return "denied"
                case .authorized: return "authorized"
                case .provisional: return "provisional"
                case .ephemeral: return "ephemeral"
                @unknown default: return "unknown(\(settings.authorizationStatus.rawValue))"
                }
            }()
            diagLog("Reminder notifications at launch: status=\(status), alerts=\(settings.alertSetting.rawValue)")
        }
    }

    /// Asks for permission once. The first reminder a note ever sets is
    /// the one the question is attached to; a refusal changes nothing
    /// about the rope and the highlight, which is the answer that works
    /// without the system's help.
    func authorize() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    diagLog("Reminder authorization failed: \(error.localizedDescription)")
                    log.error("Reminder authorization failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    diagLog("Reminder authorization: granted=\(granted)")
                }
            }
    }

    /// Where the scheduler reads the notes from, handed over at launch.
    ///
    /// The in-app ring reads this when a repeated reminder rings, to find
    /// its own next turn. The system notification stays scheduled beside
    /// the timers for the day permission arrives — but the ringing itself
    /// is ours, and it works with or without the system's blessing.
    var noteProvider: (() -> [(id: UUID, note: Note)])?

    /// One live timer per due reminder, keyed by note id. The whole of the
    /// in-app ring: a timer lands on the reminder's own second, where a
    /// polling watch could only land within five of it. No watch runs
    /// between timers — a reminder has nothing to say until its second.
    private var timers: [UUID: Timer] = [:]

    /// Rebuilds the timers from the notes. Called from `reconcile` — the
    /// same door every change walks through — so a reminder set, rewritten
    /// or taken away always leaves exactly one timer behind: its own.
    private func retime(with notes: [(id: UUID, note: Note)]) {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        let now = Date()
        for (id, note) in notes {
            guard !note.remindFired,
                  let occurrence = note.reminderOccurrence(after: now),
                  note.remindRule != nil || occurrence > now else { continue }
            scheduleTimer(id: id, at: occurrence, rule: note.remindRule)
        }
    }

    /// The timer one reminder gets. A repeated one schedules its own next
    /// turn as it rings; a one-time one is done — its mark is already set.
    private func scheduleTimer(id: UUID, at occurrence: Date, rule: Note.RepeatRule?) {
        let timer = Timer(timeInterval: max(0.1, occurrence.timeIntervalSinceNow),
                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ring(id, occurrence: occurrence)
                if rule != nil,
                   let note = self.noteProvider?().first(where: { $0.id == id })?.note,
                   let next = note.reminderOccurrence(after: occurrence) {
                    self.scheduleTimer(id: id, at: next, rule: note.remindRule)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    private func ring(_ id: UUID, occurrence: Date) {
        diagLog("Reminder ringing in-app for \(occurrence): \(id.uuidString)")
        NotificationCenter.default.post(name: Self.firedNotification, object: nil, userInfo: ["id": id])
    }

    /// Makes the pending list agree with the notes.
    ///
    /// Called from `saveNotes` — the one door every change to a note walks
    /// through — so no path can forget it: a reminder set here, rewritten
    /// there, or its card taken down entirely all arrive as the same
    /// question, and the answer is the same arithmetic every time.
    func reconcile(with notes: [(id: UUID, note: Note)]) {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        var wanted: [String: UNNotificationRequest] = [:]
        // A one-time reminder whose moment is already behind is not a thing
        // to queue — it is a thing that was due and nobody heard. It rings
        // the only way a late reminder can: at once, through the same door
        // the system's delivery uses.
        var overdue: [UUID] = []
        for (id, note) in notes {
            guard !note.remindFired,
                  let occurrence = note.reminderOccurrence(after: now) else { continue }
            guard note.remindRule != nil || occurrence > now else {
                overdue.append(id)
                continue
            }
            wanted[Self.identifier(id, for: note)] = Self.request(id: id, note: note, occurrence: occurrence)
        }
        for id in overdue {
            diagLog("Reminder overdue, ringing now: \(id.uuidString)")
            NotificationCenter.default.post(name: Self.firedNotification, object: nil, userInfo: ["id": id])
        }
        // The in-process timers are remade from the same reading, so the
        // notes and the timers cannot disagree either.
        retime(with: notes)
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            let stale = pending.filter { wanted[$0] == nil }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
                diagLog("Reminders dropped: \(stale.count)")
            }
            for (identifier, request) in wanted where !pending.contains(identifier) {
                do {
                    try await center.add(request)
                    diagLog("Reminder scheduled: \(identifier)")
                } catch {
                    diagLog("Reminder schedule failed: \(error.localizedDescription)")
                    log.error("Could not schedule a reminder: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// The schedule lives in the identifier: a changed reminder spells a
    /// different request, so the old one is dropped and the new one added
    /// and no comparison of contents is ever needed.
    private static func identifier(_ id: UUID, for note: Note) -> String {
        "note.\(id.uuidString.replacingOccurrences(of: "-", with: "")).\(Self.signature(note))"
    }

    /// The stable spelling of a schedule, for the identifier above.
    private static func signature(_ note: Note) -> String {
        guard let at = note.remindAt else { return "" }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: at)
        let minute = calendar.component(.minute, from: at)
        switch note.remindRule {
        case .daily: return "d.\(hour).\(minute)"
        case .weekly: return "w.\(calendar.component(.weekday, from: at)).\(hour).\(minute)"
        case .monthly: return "m.\(calendar.component(.day, from: at)).\(hour).\(minute)"
        case nil: return "s.\(Int(at.timeIntervalSince1970))"
        }
    }

    /// The request one note makes: its words as the banner, and a trigger
    /// that is the system's own for a repeating rule — every day, week and
    /// month at a fixed minute is a thing the notification center rings by
    /// itself, with no rescheduling to forget.
    private static func request(id: UUID, note: Note, occurrence: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = note.titleItem.map { NoteInline.rendered($0.text) } ?? L("Reminder")
        let body = note.items.dropFirst(note.titleItem == nil ? 0 : 1)
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        content.body = String(body.prefix(120))
        content.sound = .default

        let calendar = Calendar.current
        let trigger: UNNotificationTrigger
        // A repeating one whose anchor is still ahead rings its first turn
        // at the anchor itself — a date the repeating trigger cannot say,
        // for it knows [时,分] and nothing about where to begin. So the
        // first turn goes out as an exact one-time request; the rule takes
        // over from the next save onward, which the in-app ring's own
        // rescheduling does not need but the banner quietly does.
        if let at = note.remindAt, occurrence <= at {
            trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: occurrence),
                repeats: false)
        } else {
            switch note.remindRule {
            case .daily:
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.hour, .minute], from: occurrence),
                    repeats: true)
            case .weekly:
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.weekday, .hour, .minute], from: occurrence),
                    repeats: true)
            case .monthly:
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.day, .hour, .minute], from: occurrence),
                    repeats: true)
            case nil:
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: occurrence),
                    repeats: false)
            }
        }
        return UNNotificationRequest(identifier: identifier(id, for: note), content: content, trigger: trigger)
    }
}

extension ReminderScheduler: UNUserNotificationCenterDelegate {

    /// The app is always running, so a banner does not draw unless asked.
    /// The ringing itself belongs to the in-process timer; the banner here
    /// is the system's own garnish, drawn only when permission allows.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        diagLog("Reminder delivered: \(notification.request.identifier)")
        return [.banner, .sound]
    }

    /// A tap on the banner. The rope is already down — `willPresent` brought
    /// it — and the tap says the same thing again, which agreeing is free.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let id = Self.noteID(of: response.notification.request.identifier) {
            NotificationCenter.default.post(name: Self.firedNotification, object: nil, userInfo: ["id": id])
        }
    }

    /// The note's id, read back out of the request identifier.
    private static func noteID(of identifier: String) -> UUID? {
        guard identifier.hasPrefix("note.") else { return nil }
        let hex = identifier.dropFirst(5).prefix(32)
        guard hex.count == 32 else { return nil }
        let s = String(hex)
        let dashed = "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-\(s.dropFirst(12).prefix(4))"
            + "-\(s.dropFirst(16).prefix(4))-\(s.dropFirst(20))"
        return UUID(uuidString: dashed)
    }
}
