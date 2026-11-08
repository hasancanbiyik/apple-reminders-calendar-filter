import Foundation

struct ReminderList: Identifiable {
    let id: String
    let title: String
    let account: String
}

struct CalendarAccount: Identifiable {
    let id: String
    let title: String
    let isLocal: Bool
}

enum MirrorCalendarName {
    static func title(for listTitle: String) -> String { "Reminders • \(listTitle)" }

    static func migratedTitle(from currentTitle: String) -> String? {
        let legacyPrefix = "RF TEST • "
        guard currentTitle.hasPrefix(legacyPrefix) else { return nil }
        return title(for: String(currentTitle.dropFirst(legacyPrefix.count)))
    }
}

struct MirrorRecord: Codable {
    var token: UUID = UUID()
    var reminderID: String
    var externalID: String?
    var sourceID: String
    var listID: String
    var destinationCalendarID: String
    var eventID: String?
    // Written before an EventKit save, enabling recovery after interruption.
    var knownStarts: [Date] = []
    var missingSince: Date?
}

struct SavedState: Codable {
    var version: Int = 1
    var installationID: UUID = UUID()
    var selectedListIDs: Set<String> = []
    var syncEnabled = false
    var preferredSourceID: String?
    var calendars: [String: String] = [:]
    var records: [MirrorRecord] = []
    var lastSync: Date?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, installationID, selectedListIDs, syncEnabled, preferredSourceID, calendars, records, lastSync
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        installationID = try values.decode(UUID.self, forKey: .installationID)
        selectedListIDs = try values.decode(Set<String>.self, forKey: .selectedListIDs)
        syncEnabled = try values.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        preferredSourceID = try values.decodeIfPresent(String.self, forKey: .preferredSourceID)
        calendars = try values.decode([String: String].self, forKey: .calendars)
        records = try values.decode([MirrorRecord].self, forKey: .records)
        lastSync = try values.decodeIfPresent(Date.self, forKey: .lastSync)
    }
}

struct EventSchedule: Equatable {
    let start: Date
    let end: Date
    let isAllDay: Bool
    let timeZone: TimeZone?

    static func from(_ components: DateComponents, localZone: TimeZone = .current) throws -> EventSchedule {
        guard components.year != nil, components.month != nil, components.day != nil else {
            throw FilterError.message("A reminder has an incomplete due date. No cleanup was performed.")
        }
        var calendar = Calendar(identifier: .gregorian)
        let isAllDay = components.hour == nil && components.minute == nil && components.second == nil
        calendar.timeZone = isAllDay ? localZone : (components.timeZone ?? localZone)
        var due = components
        due.calendar = calendar
        due.timeZone = calendar.timeZone
        if isAllDay { due.hour = 0; due.minute = 0; due.second = 0 }
        guard let date = calendar.date(from: due),
              let end = isAllDay ? calendar.date(byAdding: .day, value: 1, to: date)
                  : calendar.date(byAdding: .minute, value: 30, to: date) else {
            throw FilterError.message("A reminder's due date could not be converted to a calendar date.")
        }
        return EventSchedule(start: date, end: end, isAllDay: isAllDay,
                             timeZone: isAllDay ? nil : components.timeZone)
    }
}

enum FilterError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let description): return description }
    }
}

struct StateFile {
    let url: URL

    static func applicationDefault() throws -> StateFile {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("RemindersCalendarFilter", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StateFile(url: directory.appendingPathComponent("state.json"))
    }

    func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw FilterError.message("Unsupported state file version. Sync is paused.") }
        guard Set(state.records.map(\.token)).count == state.records.count else {
            throw FilterError.message("Duplicate ownership records in state.json. Sync is paused.")
        }
        return state
    }

    func save(_ state: SavedState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Ownership {
    static func url(installation: UUID, token: UUID) -> URL {
        URL(string: "reminder-calendar-filter://\(installation.uuidString)/\(token.uuidString)")!
    }

    static func matches(url: URL?, calendarID: String, expectedCalendarID: String,
                        installation: UUID, token: UUID) -> Bool {
        calendarID == expectedCalendarID && url == self.url(installation: installation, token: token)
    }
}

enum RecordDisposition: Equatable {
    case keep
    case awaitConfirmation(Date)
    case remove

    static func evaluate(isDesiredInSameList: Bool, originalExists: Bool,
                         listSelected: Bool, missingSince: Date?, now: Date) -> RecordDisposition {
        if isDesiredInSameList { return .keep }
        if originalExists || !listSelected { return .remove }
        if let missingSince, now.timeIntervalSince(missingSince) >= 30 { return .remove }
        return .awaitConfirmation(missingSince ?? now)
    }
}
