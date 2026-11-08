import SwiftUI

@main
struct RemindersCalendarFilterApp: App {
    @StateObject private var controller = SyncController()

    var body: some Scene {
        MenuBarExtra("Reminder Calendars", systemImage: "calendar.badge.clock") {
            ControlPanel(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
