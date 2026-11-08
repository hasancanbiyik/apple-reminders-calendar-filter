import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    checks += 1
}

let newYork = TimeZone(identifier: "America/New_York")!
let springDay = try EventSchedule.from(DateComponents(year: 2026, month: 3, day: 8), localZone: newYork)
check(springDay.isAllDay, "date-only reminder is all-day")
check(springDay.end.timeIntervalSince(springDay.start) == 23 * 3600, "all-day end respects spring DST")
let autumnDay = try EventSchedule.from(DateComponents(year: 2026, month: 11, day: 1), localZone: newYork)
check(autumnDay.end.timeIntervalSince(autumnDay.start) == 25 * 3600, "all-day end respects autumn DST")
let midnight = try EventSchedule.from(DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 0), localZone: newYork)
check(!midnight.isAllDay, "explicit midnight remains timed")
check(midnight.end.timeIntervalSince(midnight.start) == 1800, "timed placeholder is 30 minutes")
var zoned = DateComponents(year: 2026, month: 11, day: 6, hour: 10, minute: 30)
zoned.timeZone = TimeZone(secondsFromGMT: 0)
let schedule = try EventSchedule.from(zoned, localZone: newYork)
check(schedule.timeZone == zoned.timeZone, "explicit time zone retained")
let utcCalendar = Calendar(identifier: .gregorian)
check(utcCalendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: schedule.start).hour == 10,
      "explicit due instant interpreted correctly")
do {
    _ = try EventSchedule.from(DateComponents(hour: 10))
    fatalError("FAIL: incomplete date accepted")
} catch { checks += 1 }

let installation = UUID(), token = UUID()
let ownedURL = Ownership.url(installation: installation, token: token)
check(Ownership.matches(url: ownedURL, calendarID: "owned", expectedCalendarID: "owned", installation: installation, token: token), "tracked event accepted")
check(!Ownership.matches(url: ownedURL, calendarID: "personal", expectedCalendarID: "owned", installation: installation, token: token), "moved event rejected")
check(!Ownership.matches(url: nil, calendarID: "owned", expectedCalendarID: "owned", installation: installation, token: token), "unrelated event in mirror calendar rejected")
check(!Ownership.matches(url: ownedURL, calendarID: "owned", expectedCalendarID: "owned", installation: UUID(), token: token), "different installation rejected")
check(!Ownership.matches(url: ownedURL, calendarID: "owned", expectedCalendarID: "owned", installation: installation, token: UUID()), "different tracked token rejected")

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let file = StateFile(url: temporaryDirectory.appendingPathComponent("state.json"))
var state = SavedState()
state.selectedListIDs = ["work", "study"]
state.calendars = ["work": "work-calendar", "study": "study-calendar"]
state.records = [MirrorRecord(reminderID: "reminder-1", externalID: "server-1", sourceID: "account",
    listID: "work", destinationCalendarID: "work-calendar", knownStarts: [schedule.start, midnight.start])]
try file.save(state)
let recovered = try file.load()
check(recovered.installationID == state.installationID, "installation survives restart")
check(recovered.selectedListIDs == state.selectedListIDs && recovered.calendars == state.calendars, "independent calendar bindings survive restart")
check(recovered.records[0].token == state.records[0].token && recovered.records[0].eventID == nil, "pending creation token survives interruption")
check(recovered.records[0].knownStarts.count == 2, "old and intended dates survive interrupted update")
try Data("broken".utf8).write(to: file.url)
do { _ = try file.load(); fatalError("FAIL: corrupt state silently reset") } catch { checks += 1 }
state.records.append(state.records[0])
try file.save(state)
do { _ = try file.load(); fatalError("FAIL: duplicate ownership accepted") } catch { checks += 1 }
let now = Date()
check(RecordDisposition.evaluate(isDesiredInSameList: true, originalExists: true, listSelected: true,
    missingSince: nil, now: now) == .keep, "desired copy retained independently of sidebar visibility")
check(RecordDisposition.evaluate(isDesiredInSameList: false, originalExists: false, listSelected: true,
    missingSince: nil, now: now) == .awaitConfirmation(now), "first missing snapshot cannot delete")
check(RecordDisposition.evaluate(isDesiredInSameList: false, originalExists: false, listSelected: true,
    missingSince: now.addingTimeInterval(-10), now: now) == .awaitConfirmation(now.addingTimeInterval(-10)),
    "rapid repeat sync cannot confirm deletion")
check(RecordDisposition.evaluate(isDesiredInSameList: false, originalExists: false, listSelected: true,
    missingSince: now.addingTimeInterval(-60), now: now) == .remove, "later valid missing snapshot permits owned-copy cleanup")
check(RecordDisposition.evaluate(isDesiredInSameList: false, originalExists: true, listSelected: true,
    missingSince: nil, now: now) == .remove, "explicit completion or schedule removal permits copy cleanup")
check(RecordDisposition.evaluate(isDesiredInSameList: false, originalExists: false, listSelected: false,
    missingSince: nil, now: now) == .remove, "explicit deselection permits copy cleanup")
print("Passed \(checks) core checks. No Reminders or Calendar data was accessed.")
