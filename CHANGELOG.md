# Changelog

## 0.1.2 — 2026-11-08

- Name new calendars `Reminders • List Name` instead of `RF TEST • List Name`.
- Rename existing tracked calendars with the old prefix in place on sync. Existing calendar identifiers and event mappings are retained; custom titles without that prefix are preserved.
- Explain synchronization timing and the difference between ordinary calendar events and native reminders in the README.

## 0.1.1 — 2026-11-08

First public version of Reminder Calendars.

- Mirror selected Apple Reminders lists into separate Apple Calendar calendars.
- Synchronize titles, due dates, completion, deletion, and list moves while running.
- Preserve ownership mappings across restarts and journal pending event saves.
- Support manual sync and launch at login.
- Fix the list-selection viewport collapsing and hiding checkboxes.
- Show list counts, a Refresh button, and an explicit empty-selection status.

Recurring reminders currently mirror only their exposed incomplete due item.
