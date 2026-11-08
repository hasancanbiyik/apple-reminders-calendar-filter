import AppKit
import SwiftUI

/// Renders only a fixture view offscreen. No SyncController is initialized, and
/// no user reminders, preferences, calendars, or live application UI are accessed.
@main
struct LayoutSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let fixtureLists = [
            ReminderList(id: "work", title: "Work", account: "iCloud"),
            ReminderList(id: "study", title: "Studying", account: "iCloud"),
            ReminderList(id: "personal", title: "Personal", account: "iCloud")
        ]
        let selector = ReminderListSelector(lists: fixtureLists, missingIDs: [],
            selectedIDs: ["work", "study"], isEnabled: true, onSelect: { _, _ in })
            .frame(width: 378)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: selector)
        let fittedSize = host.fittingSize
        // The old flexible ScrollView could fit at zero height in a popover.
        // Require room for all three fixture rows without proposing a height.
        guard fittedSize.height >= 140, fittedSize.width >= 370 else {
            fatalError("Reminder list viewport collapsed: \(fittedSize)")
        }
        host.frame = NSRect(origin: .zero, size: fittedSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let output = CommandLine.arguments.dropFirst().first {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fatalError("Could not allocate offscreen list render")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Could not encode list render")
            }
            try png.write(to: URL(fileURLWithPath: output))
        }
        print("Layout regression check passed: fixture viewport \(fittedSize). No user data accessed.")
        withExtendedLifetime(window) {}
    }
}
