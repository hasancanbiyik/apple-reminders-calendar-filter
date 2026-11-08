# Reminder Calendars

**Choose which Apple Reminders lists appear in Apple Calendar on your Mac.**

A lightweight SwiftUI menu bar app that mirrors selected Reminders lists into separate calendars. Show or hide each category with Apple Calendar’s existing sidebar checkboxes while continuing to create, edit, and complete tasks in Apple Reminders.

No replacement calendar interface, account signup, or external dependencies.

## How it works

Choose lists once in the menu bar app. Each gets its own calendar, such as `Reminders • Work` or `Reminders • Studying`.

| Action | Result |
| --- | --- |
| Check a mirrored calendar in Apple Calendar | Show that list’s scheduled reminder copies |
| Uncheck a mirrored calendar | Hide its copies while synchronization continues |
| Edit or complete the original in Reminders | Update or remove its calendar copy |
| Disable a list in Reminder Calendars | Remove its tracked copies; retain the calendar |

Copies are ordinary calendar events, not native reminder checkboxes. The app does not modify Apple’s built-in Scheduled Reminders filter. Turn that built-in view off to avoid seeing both originals and copies.

## Features

- Detect Reminders lists and select them with checkboxes.
- Create one calendar per selected list.
- Show date-only reminders as all-day events and timed reminders as 30-minute events.
- Synchronize titles, due dates, completion, deletion, and list moves.
- Observe EventKit changes and poll every 60 seconds while running.
- Preserve mappings across restarts and recover interrupted event saves.
- Launch at login using Apple’s ServiceManagement framework.
- Leave original reminders unchanged and restrict event updates/removals to tracked copies.

## Requirements

- macOS 14 or later.
- Apple Silicon for the build script, including MacBook Air M4. Intel has not been verified.
- Apple’s Command Line Tools or Xcode.
- Full Reminders and Calendar permissions.

Built and used on a MacBook Air M4 running macOS 15.7.4. Other macOS versions and account providers have not all been tested.

## Build and install

Download the Apple Silicon app from [GitHub Releases](https://github.com/hasancanbiyik/apple-reminders-calendar-filter/releases/latest), unzip it, quit any existing copy, and drag **Reminder Calendars.app** into **Applications**. Release builds are locally signed and not notarized; see the signing note below.

Or build from source:

```sh
git clone https://github.com/hasancanbiyik/apple-reminders-calendar-filter.git
cd apple-reminders-calendar-filter
bash scripts/build.sh
```

If Command Line Tools are missing, run `xcode-select --install` and follow Apple’s prompts.

Drag **`build/Reminder Calendars.app`** into **Applications**, then open it. Look for the calendar/clock icon in the Mac menu bar; the app does not open a Dock window.

The script signs the app locally. It is not Developer ID signed or notarized. A downloaded build may be blocked by macOS Gatekeeper; building from source creates your own locally signed copy. Signing changes can require granting permissions again.

For Xcode, open `RemindersCalendarFilter.xcodeproj`, select the **RemindersCalendarFilter** scheme and **My Mac**, then press **Command-R**. The project defaults to local ad-hoc signing. If Xcode requests a team, choose your own under Signing & Capabilities.

## First-time setup

1. Open the menu bar panel and click **Connect Reminders & Calendar**.
2. Grant full access to both. If previously denied, enable access in **System Settings → Privacy & Security**.
3. Choose the **account for new calendars**. Local accounts are preferred when available; iCloud and other writable accounts use their normal account sync settings. This choice affects newly created calendars only.
4. Select at least one Reminders list.
5. **Click Sync Now once to start synchronization.** Selecting a list alone does not start the first sync. Check the result and any error in the panel.
6. In Apple Calendar, choose **View → Show Calendar List** and uncheck **Scheduled Reminders**.
7. Use the new **Reminders • List Name** sidebar checkboxes to show or hide categories. Version 0.1.2 also renames tracked calendars with the old `RF TEST` prefix during sync, preserving their identifiers and event mappings. Custom names without that prefix are left alone.
8. Enable **Launch at login** in the app. Approve it in **System Settings → General → Login Items & Extensions** if requested.

After setup, filter categories directly in Apple Calendar. Hidden calendars keep synchronizing. Apple Calendar need not be open, but the menu bar app must remain running. Sleep and shutdown pause synchronization.

## Why updates take a few seconds

The app waits 1.5 seconds after an EventKit change notification before starting a sync, grouping changes made while typing or editing. macOS must also deliver the notification, save the mirrored event, and refresh Calendar; cloud accounts can add further delay. The 60-second polling timer is a fallback if a notification is missed. **Sync Now** skips the app’s debounce delay, but cannot force macOS or iCloud to refresh instantly.

## Creating items from Apple Calendar

An ordinary event added to a mirrored calendar stays a calendar event. It does not create an original reminder, and the app leaves untracked events alone. Editing a mirrored copy also does not update its original.

To create a real reminder inside Apple Calendar, use **+ → New Reminder** and choose the intended Reminders list. If that list is enabled in Reminder Calendars and the reminder has a due date, it will be mirrored on a later sync. This uses Apple’s native reminder creation; the app itself never writes to Reminders. See [Apple’s instructions](https://support.apple.com/guide/calendar/icl873b9a527/mac).

## Permissions and data safety

Apple’s EventKit API requires full Reminders access even to read; there is no read-only permission. **The app contains no calls to save, modify, or delete an original reminder.**

Event updates/removals require both the recorded destination calendar and a matching persisted ownership URL. The app does not adopt calendars by name, delete entire calendars, or remove untracked events, including ordinary events manually added to its calendars.

Mappings are stored locally in `Application Support/RemindersCalendarFilter/state.json` inside the app’s sandbox container. The file contains identifiers, dates, and preferences, not copied reminder titles or bodies. Keep it when updating. No analytics, external server, or app-level network connection is used; macOS manages account synchronization.

A missing/read-only tracked calendar or altered event ownership pauses synchronization rather than substituting an unrelated destination. Deleted reminders require two successful snapshots at least 30 seconds apart before cleanup. Account/server failures and identifier changes can still require manual troubleshooting.

## Current limitations

- **macOS only.** No iPhone app or integration is implemented.
- **One-way synchronization.** Edit and complete tasks in Reminders. Calendar edits do not update originals and may be overwritten.
- **Recurring reminders:** only the currently exposed incomplete due item is mirrored. Future occurrences are not expanded into a calendar series.
- Reminders without due dates are omitted. Timed copies use a fixed 30-minute display duration.
- Notes, attachments, subtasks, tags, flags, and reminder alarms are not copied. Smart lists and folders are not guaranteed to appear as EventKit lists.
- Existing destination calendars keep their names when their source list is renamed.
- Very large stores may briefly affect panel responsiveness because calendar queries run on the main actor.

## Troubleshooting

- **No lists visible:** click Refresh and check Reminders accounts and permissions. Version 0.1.1 fixes a collapsed list-selection viewport.
- **List selected but no calendar appeared:** click **Sync Now** for the initial sync. Check the updated status/time and the `Reminders • List Name` entries in Calendar’s sidebar.
- **No writable account or calendar creation fails:** create an ordinary calendar in a writable account in Apple Calendar, then refresh. Some providers do not allow additional calendars. EventKit cannot create a new local account/source.
- **Selected list unavailable:** restore its account, or use Stop mirroring for an intentionally removed list.
- **Tracked calendar missing/read-only:** restore that calendar/account. The app deliberately does not replace it automatically.
- **Event moved or ownership URL changed:** restore its original calendar/URL or delete only that mirror event so it can be recreated. Do not add recurrence rules or invitees to copies.
- **State file error:** investigate the error while keeping the state file. Deleting it loses ownership history and can leave old copies alongside new calendars.
- **Updating:** quit the old copy, replace it in Applications, and reopen it. Keep the bundle identifier and local state intact.

To remove the app, disable its selected lists if you want copies cleaned up, wait for a successful sync, disable launch at login, and quit. Empty calendars are retained for you to inspect and remove yourself.

## Development

```sh
bash scripts/test.sh         # Core checks; no user data accessed
bash scripts/test-layout.sh  # Offscreen fixture layout check on macOS
bash scripts/build.sh        # Compile and locally sign the app
```

| File | Responsibility |
| --- | --- |
| `Sources/RemindersCalendarFilterApp.swift` | Menu bar app |
| `Sources/ControlPanel.swift` | Permissions, list selection, setup, and status |
| `Sources/SyncController.swift` | EventKit reconciliation and login registration |
| `Sources/Models.swift` | Ownership, persistence, schedules, and cleanup decisions |
| `Tests/` | Core checks and list-viewport regression check |

The app uses one long-lived EventKit store, serialized access, debounced changes, and an ownership journal written before event saves. Core checks cover ownership boundaries, daylight-saving changes, explicit midnight, persistence, corrupt-state rejection, and deletion decisions. Initial live synchronization has been confirmed by the maintainer; not every account or recovery scenario has been verified.

Built with AI assistance and iterated through personal use. Bug reports and small pull requests are welcome. Include macOS version, account type, reproduction steps, and status/error text. Remove personal reminder content from screenshots and logs.

## License

[MIT](LICENSE) © Hasan Can Biyik.
