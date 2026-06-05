# EventKitLab Validation Script (V2)

**Results recorded below reflect a run on an Apple M4 MacBook Pro, macOS 15** (Phase 10). Permissions were reset before the run via `tccutil reset Calendar/AddressBook com.steak.experiments.eventkitlab` to exercise the not-determined → request flow.

Run this on a Mac with Apple Silicon running macOS 15+. You need a calendar account (iCloud, Google, Exchange, etc.) with at least a few events, some of which have video conferencing links and multiple attendees.

## Prerequisites

- EventKitLab built and running (via `xcodegen generate && open EventKitLab.xcodeproj`, then Run)
- At least one calendar account configured in System Settings > Internet Accounts
- Some events in the next 7 days (ideally including a Zoom/Meet/Teams meeting with attendees)
- Contacts app with at least a few contacts that match calendar attendees (for enrichment testing)

## Test Steps

### 1. Permission Tab -- Calendar Access

1. Open EventKitLab. You should see the **Permission** tab.
2. If calendar access has not been granted previously, you should see "Status: Not Determined" and a "Request Calendar Access" button.
3. Click **Request Calendar Access**.
4. Grant full access when the system prompt appears.
5. Verify:
   - [ ] Status changes to "Full Access" (or "Authorized (deprecated)" on older SDK paths).
   - [ ] A green checkmark icon appears next to the calendar status.

**Result:** **PASS.** Prompted on click, then status confirmed to Full Access after granting.

### 2. Permission Tab -- Contacts Access

1. On the Permission tab, under "Contacts Access", click **Request Contacts Access**.
2. Grant access when prompted.
3. Verify:
   - [ ] Status changes to "Authorized".
   - [ ] A green checkmark icon appears.

**Result:** **PASS.** Prompted on click; status changed to Authorized with green checkmark after granting.

### 3. Permission Tab -- Denial Handling

1. Open System Settings > Privacy & Security > Calendars.
2. Revoke EventKitLab's calendar access.
3. Relaunch EventKitLab.
4. Verify:
   - [ ] The Permission tab shows "Denied" status.
   - [ ] An "Open System Settings" button is shown.
   - [ ] Clicking the button opens the relevant System Settings pane.
5. Re-grant access in System Settings and relaunch EventKitLab to continue testing.

**Result:** **PASS.** After revoking calendar access and relaunching, the Permission tab showed Denied with an "Open System Settings" button that correctly opened the Calendars pane.

### 4. Calendars Tab -- Calendar Listing and Filtering

1. Switch to the **Calendars** tab.
2. Verify:
   - [ ] All your calendars appear, grouped by source (e.g. "iCloud", "Google", "Exchange").
   - [ ] Each calendar shows its color dot, title, and type label (CalDAV, Exchange, etc.).
   - [ ] All calendars are toggled ON by default.
3. Toggle OFF one calendar (e.g. "Birthdays" or a secondary calendar).
4. Verify the toggle visually reflects the change.
5. Click **Disable All**, then **Enable All**.
   - [ ] All toggles turn off, then back on.
6. Leave at least two calendars enabled (one with events, one without if possible).

**Result:** **PASS, after one bug fixed.** Calendars listed correctly (grouped by source, color dots, type labels, all on by default). **Bug:** toggles (and Enable All / Disable All) did not update the UI live — required leaving and re-entering the tab; state persisted correctly but did not re-render. **Cause:** `enabledCalendarIDs` was a computed property backed directly by `UserDefaults`, which the `@Observable` macro does not track (it only observes stored properties). **Fix:** backed the state with a stored `savedEnabledIDs: Set<String>?` (nil = all-enabled default) that the public computed property resolves and persists through, so mutations trigger SwiftUI re-render while preserving persistence and the all-enabled default. Same class of observation bug as AudioLab Phase 6b.

### 5. Events Tab -- Date Range and Event Fetching

1. Switch to the **Events** tab.
2. Adjust the date range to cover a period with known events (default is yesterday to +7 days).
3. Click **Fetch Events**.
4. Verify:
   - [ ] Events appear in the list, sorted by start date.
   - [ ] The event count label updates (e.g. "12 events loaded").
   - [ ] Each event shows its title, date/time range, and calendar name.
   - [ ] All-day events show an "All Day" badge.
   - [ ] Events with conferencing links show a blue video icon.
5. Disable a calendar on the Calendars tab, return to Events, and re-fetch.
   - [ ] Events from the disabled calendar no longer appear.

**Result:** **PASS.** Events fetched and sorted by start date, count label updated, title/time/calendar shown, all-day badges and conferencing video icons present. Disabling a calendar and re-fetching correctly removed that calendar's events.

### 6. Events Tab -- Event Detail Expansion

1. Click on an event in the list to expand it.
2. Verify the expanded view shows:
   - [ ] Organizer name and email (if available).
   - [ ] Location (if set).
   - [ ] URL (if set).
   - [ ] Conference platform and URL (if detected -- e.g. "Meet: https://meet.google.com/...").
   - [ ] Notes (if present, truncated to 5 lines).
   - [ ] Status and availability.
   - [ ] Attendee list with name, email, role, status, type.
   - [ ] "[You]" marker on the current user's attendee entry.
   - [ ] Event ID and External ID.
3. Click the same event again to collapse it.
   - [ ] The detail section hides.

**Result:** **PASS.** Expanded detail showed organizer, location/URL, conference info, notes, status/availability, attendee list with roles/status/type, "[You]" marker, and identifiers. Collapse worked.

### 7. Events Tab -- Contacts Enrichment Comparison

1. On the Events tab (with events loaded), click **Show Contacts Comparison**.
2. Expand an event that has attendees who are also in your Contacts.
3. Verify:
   - [ ] Under each attendee, a purple "Contacts enrichment" section appears.
   - [ ] For matched contacts: contact name, email, organization, and "Has photo" are shown.
   - [ ] For unmatched attendees: "No matching contact found" is shown.
   - [ ] The EK-only data (above) and Contact-enriched data (below) are visibly side-by-side for comparison.
4. Click **Hide Contacts Comparison** to toggle it off.
   - [ ] The purple enrichment sections disappear.

**Result:** **PASS mechanically; feature to be PUNTED.** The comparison toggled on/off correctly and ran the `contactPredicate` lookup against the Contacts store, but found **zero** matches — the tester does not use the Contacts app, so there was nothing to match against. No code defect. **Product takeaway:** drop Contacts-enrichment from the V1 plan — it adds a second permission prompt (`NSContactsUsageDescription`) for little value when users don't maintain Contacts. This resolves research Open Question #3 (defer Contacts enrichment). EventKit's own attendee data (name, role, status, type, and parsed email) is sufficient for the Meeting model.

### 8. Data Report Tab -- Report Generation

1. Make sure events are loaded (fetch on the Events tab first if needed).
2. Switch to the **Data Report** tab.
3. Click **Generate Report**.
4. Verify:
   - [ ] A formatted text report appears in the scrollable area.
   - [ ] The report header shows generation date and event count.
   - [ ] Each event section includes: title, start/end, all-day, calendar, color hex, status, availability, location, URL, notes, timezone, organizer details, conference info, all identifiers, and attendee details.
   - [ ] Raw EKEvent extras are included: isDetached, birthdayContactIdentifier, structuredLocation (with geo if available), creationDate, lastModifiedDate, recurrence rules, alarms.
   - [ ] If Contacts enrichment was run, a "Contacts Enrichment Comparison" section appears at the bottom showing match statistics and per-attendee comparison.
5. Click **Copy to Clipboard**.
   - [ ] "Copied!" confirmation appears briefly.
   - [ ] Paste into a text editor to confirm the full report was copied.

**Result:** **PASS (low value).** Report generated and copy-to-clipboard worked. Tester noted this test is largely a copy/paste check; the underlying field availability is already covered by the Events-tab detail (Test 6) and documented in `research/eventkit/README.md` §3.

### 9. Conference URL Detection (Spot Check)

1. If you have an event with a Zoom, Google Meet, or Teams link in its notes, location, or URL field, verify it was detected:
   - [ ] The event shows the blue video icon in the list.
   - [ ] The expanded detail shows the correct platform name and conference URL.
2. If you have an event without any conferencing link:
   - [ ] No video icon is shown, and no conference info appears in the detail.

**Result:** **PASS.** Conference detection worked well on real events — video icon shown and correct platform + join URL surfaced in detail; non-conferencing events showed no icon. Caveat: the regex set will need ongoing tuning to cover more platforms/URL formats, but the parse-from-notes/location/url approach is validated as sound.

### 10. Empty State Handling

1. On the Calendars tab, click **Disable All**.
2. Go to the Events tab and click **Fetch Events**.
   - [ ] The event list is empty.
   - [ ] A message like "No events in the selected range..." is shown.
3. Go to the Data Report tab.
   - [ ] The "Generate Report" button is disabled (no events loaded).
4. Re-enable calendars on the Calendars tab.

**Result:** **PASS (low value).** Disabling all calendars produced an empty event list as expected. A basic smoke check.

## Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| 1. Calendar Access | PASS | Prompt + Full Access confirmed. |
| 2. Contacts Access | PASS | Prompt + Authorized confirmed. |
| 3. Denial Handling | PASS | Denied state + working "Open System Settings". |
| 4. Calendar Filtering | PASS (1 bug fixed) | Toggles didn't refresh live — fixed observable state (UserDefaults-backed computed property not tracked by `@Observable`). |
| 5. Event Fetching | PASS | Sorted, counted, calendar-filtered correctly. |
| 6. Event Detail | PASS | All fields + "[You]" + identifiers shown. |
| 7. Contacts Enrichment | PUNTED | Worked mechanically; 0 matches (tester doesn't use Contacts). Drop from V1. |
| 8. Data Report | PASS (low value) | Copy/paste smoke check. |
| 9. Conference Detection | PASS | Works well on real meetings; regex needs ongoing tuning. |
| 10. Empty States | PASS (low value) | Empty-list smoke check. |
