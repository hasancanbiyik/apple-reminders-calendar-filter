import SwiftUI
import ServiceManagement
import AppKit

struct ControlPanel: View {
    @ObservedObject var controller: SyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reminder Calendars").font(.headline)
                    Text("Choose lists once. Filter in Apple Calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
            }
            Divider()
            if !controller.hasAccess {
                Text("Read scheduled reminders and create a separate test calendar for each chosen list. Original reminders are never changed.")
                    .font(.callout)
                Button("Connect Reminders & Calendar") { Task { await controller.connect() } }
                    .buttonStyle(.borderedProminent).disabled(controller.isBusy)
                Text("macOS requires full access to read reminders and maintain mirrored events.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
            } else {
                HStack {
                    Text("Lists to make filterable").font(.subheadline.bold())
                    Spacer()
                    Button("Refresh") { controller.refreshLists() }
                        .disabled(controller.isBusy)
                }
                Text("\(controller.lists.count) lists found · \(controller.state.selectedListIDs.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.lists.isEmpty {
                    Text("No lists found. Open Reminders to check your accounts, then click Refresh.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !controller.lists.isEmpty || !controller.missingListIDs.isEmpty {
                    ReminderListSelector(lists: controller.lists,
                        missingIDs: controller.missingListIDs,
                        selectedIDs: controller.state.selectedListIDs,
                        isEnabled: controller.canConfigure,
                        onSelect: { controller.select($0, enabled: $1) })
                }
                if controller.state.selectedListIDs.isEmpty && !controller.lists.isEmpty {
                    Label("Select at least one list above to create its calendar.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("To hide a category, uncheck its calendar in Apple Calendar. Turning off a list here removes its copies.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Picker("Account for new calendars", selection: $controller.selectedAccountID) {
                    if controller.accounts.isEmpty { Text("No writable account").tag("") }
                    ForEach(controller.accounts) { account in
                        Text(account.title + (account.isLocal ? " (local)" : "")).tag(account.id)
                    }
                }.disabled(!controller.canConfigure)
                Text("Creates Reminders • List calendars in this account. Cloud accounts use their normal sync settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { controller.loginStatus == .enabled || controller.loginStatus == .requiresApproval },
                set: { controller.setLaunchAtLogin($0) }
            )).toggleStyle(.switch)
            if controller.loginStatus == .requiresApproval {
                Button("Approve in Login Items Settings…") { controller.openLoginSettings() }
            }
            Text(controller.loginStatus == .enabled
                 ? "Runs quietly at login. Hidden calendars keep syncing."
                 : "Install the app in Applications, then enable launch at login.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let date = controller.state.lastSync {
                    Text("Last synced: \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Sync Now") { Task { await controller.sync(manual: true) } }
                    .disabled(!controller.canConfigure)
                Button("Open Calendar") {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            Text("In Calendar, turn off Scheduled Reminders and use each Reminders • List calendar checkbox. Edit tasks in Reminders. Repeating tasks show their current due item only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 410)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A menu bar popover gives a ScrollView no intrinsic height. A maximum alone
/// permits a zero-height viewport, hiding every checkbox even with loaded lists.
struct ReminderListSelector: View {
    let lists: [ReminderList]
    let missingIDs: [String]
    let selectedIDs: Set<String>
    let isEnabled: Bool
    let onSelect: (String, Bool) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lists) { list in
                    Toggle(isOn: Binding(
                        get: { selectedIDs.contains(list.id) },
                        set: { onSelect(list.id, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.title).lineLimit(2)
                            Text(list.account).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.checkbox).disabled(!isEnabled)
                }
                ForEach(missingIDs, id: \.self) { id in
                    HStack {
                        Text("Unavailable selected list").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Stop mirroring") { onSelect(id, false) }.disabled(!isEnabled)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(180, max(72, CGFloat(lists.count + missingIDs.count) * 48 + 16)))
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
