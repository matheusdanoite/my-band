import Foundation
import OSLog
import EventKit

// MARK: - CalendarSyncService
//
// Pushes phone-side configuration TO the band (app → band, encrypted):
//   • UI language   (System / CMD_LANGUAGE)        — from the current locale
//   • calendar events (CMD_CALENDAR_SET)           — EventKit, next 30 days, ≤50 events
//   • reminders     (Schedule / CMD_REMINDERS_*)   — EventKit reminders with a due date, ≤20
//
// Calendar sync is replace-semantics (the band swaps its whole event set), so it's idempotent.
// Reminders have no bulk-replace, so we track the ids we created and delete them before
// re-creating — this mirrors the iPhone's reminders without accumulating duplicates on the band.

@MainActor
final class CalendarSyncService {

    private weak var bandManager: BandManager?
    private let store = EKEventStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "CalSync")

    private let maxEvents = 50
    private let maxReminders = 20
    private let createdReminderIDsKey = "myband.createdReminderIDs"

    // Each section is pushed on every sync, but the payloads rarely change between syncs (language
    // almost never, calendar/reminders only when the user edits them). Pushing an unchanged set every
    // few minutes is wasted radio time and, for reminders, a needless delete+recreate churn on the
    // band. We cache a stable signature of the last successfully-sent payload and skip when it matches.
    private let lastLanguageKey  = "myband.lastPushedLanguage"
    private let lastCalendarKey  = "myband.lastPushedCalendarSig"
    private let lastRemindersKey = "myband.lastPushedRemindersSig"

    /// Launch-stable signature (Swift's Hashable is per-process salted, so it can't be persisted).
    private func signature(_ s: String) -> String {
        String(Checksums.crc32(Data(s.utf8)), radix: 16)
    }

    func setup(manager: BandManager) {
        bandManager = manager
    }

    // MARK: - Push entry point

    /// Pushes language, calendar and reminders to the band. Each section is independent: a denied
    /// permission or empty data set skips that section without blocking the others.
    func pushAll() async {
        guard bandManager?.connectionState.isConnected == true else { return }
        pushLanguage()
        await pushCalendar()
        await pushReminders()
    }

    // MARK: - Language

    private func pushLanguage() {
        // Locale.current reflects the app's resolved locale, which may fall back to English
        // when the app has no localization for the user's language — even if the user's preferred
        // language is something else (e.g. pt-BR). Locale.preferredLanguages.first always returns the user's actual choice.
        let raw    = Locale.preferredLanguages.first ?? "en-US"
        let locale = Locale(identifier: raw)
        let lang   = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? Locale.current.region?.identifier ?? "US"
        let code   = "\(lang)_\(region)".lowercased()
        guard UserDefaults.standard.string(forKey: lastLanguageKey) != code else {
            log.debug("Language unchanged (\(code)) — skipping push")
            return
        }
        log.info("Pushing language: \(code)")
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.languageCommand(code: code))
        UserDefaults.standard.set(code, forKey: lastLanguageKey)
    }

    // MARK: - Calendar

    private func pushCalendar() async {
        guard await requestEventsAccess() else {
            log.info("Calendar access not granted — skipping")
            return
        }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(maxEvents)
            .map { ev -> Xiaomi_CalendarEvent in
                var e = Xiaomi_CalendarEvent()
                e.title    = ev.title ?? ""
                if let notes = ev.notes, !notes.isEmpty { e.description_p = notes }
                if let loc = ev.location, !loc.isEmpty { e.location = loc }
                e.start  = UInt32(ev.startDate.timeIntervalSince1970)
                e.end    = UInt32(ev.endDate.timeIntervalSince1970)
                e.allDay = ev.isAllDay
                // First relative alarm (minutes before start) maps to the band's reminder.
                if let offset = ev.alarms?.compactMap({ $0.relativeOffset }).min(), offset < 0 {
                    e.notifyMinutesBefore = UInt32((-offset) / 60)
                }
                return e
            }
        let sig = signature(events.map { "\($0.title)|\($0.start)|\($0.end)|\($0.allDay)|\($0.notifyMinutesBefore)" }
            .joined(separator: ";"))
        guard UserDefaults.standard.string(forKey: lastCalendarKey) != sig else {
            log.debug("Calendar unchanged (\(events.count) event(s)) — skipping push")
            return
        }
        log.info("Pushing \(events.count) calendar event(s)")
        bandManager?.sendEncryptedCommand(
            protoBytes: XiaomiProto.calendarSyncCommand(events: Array(events), disabled: events.isEmpty)
        )
        UserDefaults.standard.set(sig, forKey: lastCalendarKey)
    }

    // MARK: - Reminders

    private func pushReminders() async {
        guard await requestRemindersAccess() else {
            log.info("Reminders access not granted — skipping")
            return
        }

        let reminders = await fetchDueReminders()

        // Skip the delete+recreate churn when the due-reminder set hasn't changed since the last
        // push. The persisted band-assigned ids stay valid, so there's nothing to reconcile.
        let sig = signature(reminders.prefix(maxReminders)
            .map { "\($0.title ?? "")|\($0.dueDateComponents?.date?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: ";"))
        guard UserDefaults.standard.string(forKey: lastRemindersKey) != sig else {
            log.debug("Reminders unchanged — skipping push")
            return
        }

        // Clear the reminders we created on a previous sync before re-creating, so the band mirrors
        // the current state instead of accumulating. The ids are the band-assigned ones captured
        // from the create-acks of the previous run (see below).
        let previous = UserDefaults.standard.array(forKey: createdReminderIDsKey) as? [Int] ?? []
        if !previous.isEmpty {
            bandManager?.sendEncryptedCommand(
                protoBytes: XiaomiProto.reminderDeleteCommand(ids: previous.map { UInt32($0) })
            )
        }

        // The band assigns each reminder's id and returns it via schedule.ackId. Collect those acks
        // so we know what to delete next time.
        var ackedIDs: [Int] = []
        bandManager?.onScheduleAck = { id in ackedIDs.append(Int(id)) }
        defer { bandManager?.onScheduleAck = nil }

        var sent = 0
        for reminder in reminders.prefix(maxReminders) {
            guard let due = reminder.dueDateComponents?.date else { continue }
            let details = XiaomiProto.reminderDetails(date: due, title: reminder.title ?? "Reminder")
            bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderCreateCommand(details))
            sent += 1
        }

        // Give the band a moment to ack each create before persisting the ids it assigned.
        try? await Task.sleep(for: .seconds(2))
        UserDefaults.standard.set(ackedIDs, forKey: createdReminderIDsKey)
        UserDefaults.standard.set(sig, forKey: lastRemindersKey)
        log.info("Pushed \(sent) reminder(s), \(ackedIDs.count) acked")
    }

    private func fetchDueReminders() async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let withDue = (reminders ?? [])
                    .filter { $0.dueDateComponents?.date != nil }
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                cont.resume(returning: withDue)
            }
        }
    }

    // MARK: - Authorization (iOS 17+ full-access APIs)

    private func requestEventsAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    private func requestRemindersAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }
}
