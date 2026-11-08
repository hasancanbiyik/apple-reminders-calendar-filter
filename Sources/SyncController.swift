import AppKit
import Combine
import EventKit
import ServiceManagement

/// All EventKit access is serialized on the main actor. Reminder fetches are asynchronous.
/// There are deliberately no calls to save/remove an EKReminder anywhere in this app.
@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var accounts: [CalendarAccount] = []
    @Published private(set) var state = SavedState()
    @Published private(set) var hasAccess = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var summary = "Connect to Reminders and Calendar to begin."
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published var selectedAccountID = ""

    private let store = EKEventStore()
    private var stateFile: StateFile?
    private var persistenceFailed = false
    private var observers: Set<AnyCancellable> = []
    private var timer: Timer?
    private var changeRevision = 0
    private var pendingSync: DispatchWorkItem?
    private var eventQueryCache: [String: [EKEvent]] = [:]

    init() {
        do {
            let file = try StateFile.applicationDefault()
            state = try file.load()
            try file.save(state) // Persist the ownership namespace before any EventKit writes.
            stateFile = file
        } catch {
            persistenceFailed = true
            errorMessage = "Cannot safely load sync state: \(error.localizedDescription)"
        }

        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.changeRevision += 1
                self.scheduleSync()
            }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleSync() }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loginStatus = SMAppService.mainApp.status
                self?.scheduleSync()
            }.store(in: &observers)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        refreshAccess()
        if hasAccess {
            summary = state.syncEnabled ? "Background sync is starting…" : "Choose lists and an account, then click Sync Now."
            scheduleSync()
        }
    }

    var missingListIDs: [String] {
        state.selectedListIDs.subtracting(Set(lists.map(\.id))).sorted()
    }

    var canConfigure: Bool { hasAccess && !isBusy && !persistenceFailed }

    func isSelected(_ id: String) -> Bool { state.selectedListIDs.contains(id) }

    func refreshLists() {
        guard !isBusy else { return }
        refreshAccess()
        if hasAccess && state.selectedListIDs.isEmpty && state.records.isEmpty {
            summary = lists.isEmpty ? "No Reminders lists found. Check Reminders, then refresh."
                : "No lists selected. Choose at least one list above."
        }
    }

    func select(_ id: String, enabled: Bool) {
        guard canConfigure else { return }
        if enabled { state.selectedListIDs.insert(id) } else { state.selectedListIDs.remove(id) }
        do { try persist(); scheduleSync() } catch { report(error) }
    }

    func connect() async {
        guard !isBusy, !persistenceFailed else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let remindersGranted = try await store.requestFullAccessToReminders()
            guard remindersGranted else { throw FilterError.message("Allow Reminders access in System Settings → Privacy & Security → Reminders.") }
            let calendarsGranted = try await store.requestFullAccessToEvents()
            guard calendarsGranted else { throw FilterError.message("Allow full Calendar access in System Settings → Privacy & Security → Calendars.") }
            refreshAccess()
            errorMessage = nil
            summary = "Select the lists to make filterable, then sync."
        } catch { refreshAccess(); report(error) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { loginStatus = SMAppService.mainApp.status; report(error) }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func refreshAccess() {
        hasAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            && EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else { return }
        lists = store.calendars(for: .reminder).map {
            ReminderList(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title)
        }.sorted { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }

        let writableSources = Set(store.calendars(for: .event)
            .filter { $0.allowsContentModifications && !$0.isSubscribed }
            .map { $0.source.sourceIdentifier })
        accounts = store.sources.filter {
            $0.sourceType == .local || (writableSources.contains($0.sourceIdentifier)
                && ($0.sourceType == .calDAV || $0.sourceType == .exchange))
        }.map {
            CalendarAccount(id: $0.sourceIdentifier, title: $0.title, isLocal: $0.sourceType == .local)
        }.sorted { ($0.isLocal ? 0 : 1, $0.title) < ($1.isLocal ? 0 : 1, $1.title) }
        if !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = accounts.first(where: { $0.id == state.preferredSourceID })?.id
                ?? accounts.first?.id ?? ""
        }
    }

    private func persist() throws {
        guard let stateFile, !persistenceFailed else {
            throw FilterError.message("Sync state is unavailable. Restart after resolving the file error.")
        }
        do { try stateFile.save(state) }
        catch { persistenceFailed = true; throw error }
    }

    private func report(_ error: Error) { errorMessage = error.localizedDescription }

    private func scheduleSync() {
        pendingSync?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.sync() }
        }
        pendingSync = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func fetchAllReminders() async throws -> [EKReminder] {
        // nil calendars means all accessible lists; nil *results* are an error, not an empty snapshot.
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var request: Any?
            request = store.fetchReminders(matching: predicate) { reminders in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    if let reminders { continuation.resume(returning: reminders) }
                    else { continuation.resume(throwing: FilterError.message("Reminders returned no valid snapshot. Nothing was removed.")) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard !finished else { return }
                finished = true
                if let request { self?.store.cancelFetchRequest(request) }
                continuation.resume(throwing: FilterError.message("Reading Reminders timed out. Sync will retry; nothing was removed."))
            }
        }
    }

    /// Never adopt a calendar by name. Only identifiers recorded at creation are accepted.
    private func existingDestination(_ id: String) throws -> EKCalendar {
        guard state.calendars.values.contains(id),
              let calendar = store.calendar(withIdentifier: id),
              calendar.allowedEntityTypes.contains(.event), calendar.allowsContentModifications,
              !calendar.isSubscribed else {
            throw FilterError.message("A tracked reminder calendar is missing or read-only. Restore it or its account before syncing. The app will not substitute another calendar.")
        }
        return calendar
    }

    private func destination(for listID: String) throws -> EKCalendar {
        if let id = state.calendars[listID] { return try existingDestination(id) }
        guard let list = lists.first(where: { $0.id == listID }),
              accounts.contains(where: { $0.id == selectedAccountID }),
              let source = store.source(withIdentifier: selectedAccountID) else {
            throw FilterError.message("Choose a writable account for the new reminder calendars. If none appears, add a local or iCloud calendar in Apple Calendar first.")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = MirrorCalendarName.title(for: list.title)
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        state.calendars[listID] = calendar.calendarIdentifier
        try persist()
        return calendar
    }

    private func migrateCalendarNames() throws {
        // Only calendars whose identifiers we persisted at creation are eligible.
        // Rename in place: retain bindings, events, colors, and visibility. Custom
        // titles without the old generated prefix are left alone.
        for id in Set(state.calendars.values).sorted() {
            guard let calendar = store.calendar(withIdentifier: id),
                  calendar.allowedEntityTypes.contains(.event),
                  calendar.allowsContentModifications, !calendar.isSubscribed,
                  let title = MirrorCalendarName.migratedTitle(from: calendar.title) else { continue }
            calendar.title = title
            try store.saveCalendar(calendar, commit: true)
        }
    }

    private func assertOwned(_ event: EKEvent, record: MirrorRecord) throws {
        guard Ownership.matches(url: event.url, calendarID: event.calendar.calendarIdentifier,
                expectedCalendarID: record.destinationCalendarID,
                installation: state.installationID, token: record.token),
              !event.hasRecurrenceRules, !event.hasAttendees else {
            throw FilterError.message("A tracked event was moved, its ownership URL was changed, or recurrence/invitees were added. Sync stopped without modifying that event. Restore its original calendar and URL, and remove added recurrence/invitees.")
        }
    }

    private func candidates(for record: MirrorRecord, desiredStart: Date?) throws -> [EKEvent] {
        let calendar = try existingDestination(record.destinationCalendarID)
        var matches: [String: EKEvent] = [:]
        if let id = record.eventID, let event = store.event(withIdentifier: id) {
            try assertOwned(event, record: record)
            matches[event.calendarItemIdentifier] = event
        }
        // Annual queries stay below EventKit's four-year predicate limit.
        // Only years relevant to this tracked item are searched, even for distant due dates.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let starts = record.knownStarts + (desiredStart.map { [$0] } ?? [])
        let years = Set(starts.map { gregorian.component(.year, from: $0) })
        for year in years {
            guard let start = gregorian.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = gregorian.date(byAdding: .year, value: 1, to: start) else { continue }
            let cacheKey = "\(calendar.calendarIdentifier)|\(year)"
            if eventQueryCache[cacheKey] == nil {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
                eventQueryCache[cacheKey] = store.events(matching: predicate)
            }
            for event in eventQueryCache[cacheKey]!
                where event.url == Ownership.url(installation: state.installationID, token: record.token) {
                try assertOwned(event, record: record)
                matches[event.calendarItemIdentifier] = event
            }
        }
        return matches.values.sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }
    }

    private func removeCopies(for record: MirrorRecord) throws -> Int {
        let events = try candidates(for: record, desiredStart: nil)
        for event in events {
            try assertOwned(event, record: record)
            try store.remove(event, span: .thisEvent, commit: true)
        }
        return events.count
    }

    func sync(manual: Bool = false) async {
        guard !isBusy, !persistenceFailed, state.syncEnabled || manual else { return }
        refreshAccess()
        guard hasAccess else {
            if !state.records.isEmpty { errorMessage = "Sync is paused. Restore full Calendar and Reminders permissions." }
            return
        }
        isBusy = true
        eventQueryCache = [:]
        defer { isBusy = false; eventQueryCache = [:] }
        do {
            if state.selectedListIDs.isEmpty && state.records.isEmpty {
                summary = lists.isEmpty ? "No Reminders lists found. Check Reminders, then refresh."
                    : "No lists selected. Choose at least one list above."
                errorMessage = nil
                return
            }
            guard missingListIDs.isEmpty else {
                throw FilterError.message("A selected Reminders list is unavailable. Restore its account, or remove the missing list in this panel. No events were changed.")
            }
            if manual {
                state.syncEnabled = true
                state.preferredSourceID = selectedAccountID
                try persist()
            }
            let revision = changeRevision
            let reminderListsBefore = Set(lists.map(\.id))
            let reminders = try await fetchAllReminders()
            refreshAccess()
            guard hasAccess, changeRevision == revision,
                  Set(lists.map(\.id)) == reminderListsBefore else {
                scheduleSync()
                throw FilterError.message("Reminders changed while being read. Waiting for a stable snapshot before syncing.")
            }
            guard Set(reminders.map(\.calendarItemIdentifier)).count == reminders.count else {
                throw FilterError.message("Reminders returned ambiguous identifiers. Sync paused.")
            }
            let byID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.calendarItemIdentifier, $0) })
            // Rebind changed local identifiers only with an unambiguous server ID in the same account.
            for index in state.records.indices {
                let record = state.records[index]
                if byID[record.reminderID] == nil, let externalID = record.externalID {
                    let matches = reminders.filter {
                        $0.calendarItemExternalIdentifier == externalID && $0.calendar.source.sourceIdentifier == record.sourceID
                    }
                    guard matches.count <= 1 else { throw FilterError.message("A reminder identity is ambiguous after an account sync. No cleanup was performed.") }
                    if let reminder = matches.first {
                        state.records[index].reminderID = reminder.calendarItemIdentifier
                    }
                }
            }
            guard Set(state.records.map(\.reminderID)).count == state.records.count else {
                throw FilterError.message("Overlapping reminder mappings detected. Sync paused to avoid duplicates.")
            }

            let desired = reminders.filter {
                state.selectedListIDs.contains($0.calendar.calendarIdentifier)
                    && !$0.isCompleted && $0.dueDateComponents != nil
            }
            // Validate every desired date before creating, updating, or deleting any event.
            var schedules: [String: EventSchedule] = [:]
            for reminder in desired {
                schedules[reminder.calendarItemIdentifier] = try EventSchedule.from(reminder.dueDateComponents!)
            }
            for record in state.records { _ = try existingDestination(record.destinationCalendarID) }
            try migrateCalendarNames()
            var destinations: [String: EKCalendar] = [:]
            for listID in state.selectedListIDs.sorted() { destinations[listID] = try destination(for: listID) }

            var removed = 0
            var created = 0
            var updated = 0
            var waiting = 0
            // Explicit completion/deselection/date removal is immediate. Missing items need two
            // successful snapshots at least 30 seconds apart, reducing transient account-sync risk.
            for index in state.records.indices.reversed() {
                let record = state.records[index]
                let reminder = byID[record.reminderID]
                let desiredHere = reminder.map {
                    schedules[$0.calendarItemIdentifier] != nil && $0.calendar.calendarIdentifier == record.listID
                } ?? false
                switch RecordDisposition.evaluate(isDesiredInSameList: desiredHere,
                    originalExists: reminder != nil, listSelected: state.selectedListIDs.contains(record.listID),
                    missingSince: record.missingSince, now: Date()) {
                case .keep:
                    state.records[index].missingSince = nil
                    continue
                case .awaitConfirmation(let since):
                    state.records[index].missingSince = since
                    waiting += 1
                    continue
                case .remove:
                    break
                }
                removed += try removeCopies(for: record)
                state.records.remove(at: index)
                try persist()
            }

            for reminder in desired {
                let reminderID = reminder.calendarItemIdentifier
                let listID = reminder.calendar.calendarIdentifier
                let schedule = schedules[reminderID]!
                let calendar = destinations[listID]!
                var index: Int
                if let existing = state.records.firstIndex(where: { $0.reminderID == reminderID }) { index = existing }
                else {
                    // An unmatched item could be the same reminder with a new local ID.
                    // Finish confirming/removing missing mappings before making new copies.
                    if waiting > 0 { continue }
                    state.records.append(MirrorRecord(reminderID: reminderID,
                        externalID: reminder.calendarItemExternalIdentifier,
                        sourceID: reminder.calendar.source.sourceIdentifier,
                        listID: listID, destinationCalendarID: calendar.calendarIdentifier))
                    index = state.records.count - 1
                }
                // Write-ahead journal: retain old and intended dates until the event save is recorded.
                if !state.records[index].knownStarts.contains(schedule.start) {
                    state.records[index].knownStarts.append(schedule.start)
                    try persist()
                }
                let record = state.records[index]
                let existingEvents = try candidates(for: record, desiredStart: schedule.start)
                let event = existingEvents.first ?? EKEvent(eventStore: store)
                let isNew = existingEvents.isEmpty
                let notes = "Mirrored from Reminders: \(reminder.calendar.title)\nEdit or complete the original in Reminders. Calendar edits are not synced back."
                let title = reminder.title ?? "Untitled reminder"
                let needsUpdate = isNew || event.title != title || event.startDate != schedule.start
                    || event.endDate != schedule.end || event.isAllDay != schedule.isAllDay
                    || event.timeZone != schedule.timeZone || event.notes != notes
                if needsUpdate {
                    if !isNew { try assertOwned(event, record: record) }
                    event.calendar = calendar
                    event.title = title
                    event.isAllDay = schedule.isAllDay
                    event.timeZone = schedule.timeZone
                    event.startDate = schedule.start
                    event.endDate = schedule.end
                    event.url = Ownership.url(installation: state.installationID, token: record.token)
                    event.notes = notes
                    event.alarms = nil
                    if calendar.supportedEventAvailabilities.contains(.free) { event.availability = .free }
                    try assertOwned(event, record: record)
                    try store.save(event, span: .thisEvent, commit: true)
                    if isNew { created += 1 } else { updated += 1 }
                }
                let mappingChanged = state.records[index].eventID != event.eventIdentifier
                    || state.records[index].externalID != reminder.calendarItemExternalIdentifier
                    || state.records[index].sourceID != reminder.calendar.source.sourceIdentifier
                state.records[index].eventID = event.eventIdentifier
                state.records[index].externalID = reminder.calendarItemExternalIdentifier
                state.records[index].sourceID = reminder.calendar.source.sourceIdentifier
                if needsUpdate || mappingChanged { try persist() }
                // Recover and remove duplicate copies only for this persisted ownership token.
                for duplicate in existingEvents.dropFirst() {
                    try assertOwned(duplicate, record: record)
                    try store.remove(duplicate, span: .thisEvent, commit: true)
                    removed += 1
                }
                if state.records[index].knownStarts != [schedule.start] {
                    state.records[index].knownStarts = [schedule.start]
                    try persist()
                }
            }
            state.lastSync = Date()
            try persist()
            errorMessage = nil
            summary = "\(desired.count) mirrored · \(created) added · \(updated) updated · \(removed) removed"
            if waiting > 0 { summary += " · \(waiting) awaiting deletion confirmation" }
        } catch { report(error) }
    }
}
