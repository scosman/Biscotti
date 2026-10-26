/// The Microsoft 365 Calendar manual test script (Synderys fork,
/// o365_calendar Phase 3).
///
/// One pass on the real app against a real tenant: sign in, check that
/// the Graph calendars feed Home, Settings, onboarding, the event picker
/// and speaker naming, then exercise relaunch, offline and Disconnect.
/// Two questions settle the open questions in the functional spec (§8):
/// how all-day events come back under the UTC `Prefer` header (Q1) and
/// whether shared calendars read or are skipped with a 403 (Q4).
public extension TestScript {
    static let microsoft365Calendar = TestScript(
        id: "m365_calendar",
        title: "M365 Calendar",
        steps: [
            // 1. Setup instruction (passive text)
            .instruction(
                id: "m365_setup",
                text: "Run the real Biscotti app (not ManualTestApp) with the "
                    + "Entra registration set: `defaults read "
                    + "com.synderys.biscotti MicrosoftGraphClientID` and "
                    + "`MicrosoftGraphTenantID` must both print an ID "
                    + "(see docs/entra_app_registration.md). In Outlook, have "
                    + "a Teams meeting with at least one other attendee in "
                    + "the next few days, an all-day event this week, and, "
                    + "if you can, a calendar someone shared with you. "
                    + "In Terminal, stream the log: `log stream --level "
                    + "debug --predicate 'subsystem == "
                    + "\"net.scosman.biscotti\" AND (category == "
                    + "\"GraphCalendar\" OR category == \"GraphAuth\" OR "
                    + "category == \"AppCore\")'`."
            ),
            // 2. Sign-in and Settings (recordable)
            .humanQuestion(
                id: "m365_connect",
                prompt: "In Settings → Calendars, click “Connect…” and sign "
                    + "in in the browser. Does the row show your account and "
                    + "“Synced just now”, with your calendars listed under it? "
                    + "Is the Apple Calendar row gone from Settings → "
                    + "Permissions?"
            ),
            // 3. Home upcoming list (recordable)
            .humanQuestion(
                id: "m365_upcoming",
                prompt: "Does Home's upcoming list show your Microsoft 365 "
                    + "meetings at the right times, with “Join & Record” on "
                    + "the Teams meeting? Untick a calendar in Settings → "
                    + "Calendars: do its meetings leave the list? Tick it "
                    + "again."
            ),
            // 4. New event reaches the app (recordable)
            .humanQuestion(
                id: "m365_new_event",
                prompt: "In Outlook, create a meeting with another attendee "
                    + "starting in about 15 minutes. Does it appear in "
                    + "Home's upcoming list within 5 minutes, without "
                    + "relaunching?"
            ),
            // 5. All-day events, functional spec Q1 (recordable)
            .humanQuestion(
                id: "m365_all_day",
                prompt: "All-day events never show in the app (they are not "
                    + "meetings), so this one is read from the log. Does "
                    + "the log stream show an “All-day bounds:” line for "
                    + "this week's all-day event, with dates matching the "
                    + "day in Outlook? Paste the line into the note: it "
                    + "shows which form Graph sends."
            ),
            // 6. Shared calendars, functional spec Q4 (recordable)
            .humanQuestion(
                id: "m365_shared_calendar",
                prompt: "If a calendar is shared with you (e.g. an EA's or a "
                    + "manager's): is it listed in Settings → Calendars, and "
                    + "do its meetings show on Home? Or does the log say "
                    + "“Skipping calendar …: forbidden”? Note which. Mark "
                    + "Skip if you have no shared calendar."
            ),
            // 7. Event picker on an older recording (recordable)
            .humanQuestion(
                id: "m365_picker",
                prompt: "Open a recording from more than a week ago and "
                    + "choose “Link Calendar Event…” (or “Change Calendar "
                    + "Event…”). Within a few seconds, does the picker list "
                    + "the Microsoft 365 meetings from around that time, and "
                    + "does picking one link it (title and attendees on the "
                    + "meeting)?"
            ),
            // 8. Invitees reach speaker naming (recordable)
            .humanQuestion(
                id: "m365_speaker_names",
                prompt: "With AI Enhancements on, record a short call with "
                    + "at least two voices while a Microsoft 365 meeting with "
                    + "other attendees is on (e.g. the one from the "
                    + "new-event step), so the recording links to it. After "
                    + "transcription, does the meeting show the attendees, "
                    + "and do the suggested speaker names come from them?"
            ),
            // 9. Onboarding (recordable)
            .humanQuestion(
                id: "m365_onboarding",
                prompt: "In a Debug build, use Settings → Debug → “Replay "
                    + "Onboarding”. Does the permissions step show a "
                    + "Microsoft 365 row (already connected) in place of "
                    + "Calendar access, and does the calendar step list your "
                    + "Microsoft 365 calendars?"
            ),
            // 10. Relaunch (recordable)
            .humanQuestion(
                id: "m365_relaunch",
                prompt: "Quit and relaunch Biscotti. Does the upcoming list "
                    + "fill without signing in again? If macOS asks for "
                    + "keychain access, click “Always Allow”: does the "
                    + "prompt stay away on the next relaunch? Note whether "
                    + "it appeared."
            ),
            // 11. Offline (recordable)
            .humanQuestion(
                id: "m365_offline",
                prompt: "With the app running, turn Wi-Fi off, then put the "
                    + "Mac to sleep and wake it (that triggers a sync). Does "
                    + "Home keep its meetings, and does Settings → Calendars "
                    + "show a red message that Microsoft 365 couldn't be "
                    + "reached? Turn Wi-Fi back on: within a minute, does "
                    + "the message clear and the sync time update?"
            ),
            // 12. Disconnect (recordable)
            .humanQuestion(
                id: "m365_disconnect",
                prompt: "In Settings → Calendars, click “Disconnect…” and "
                    + "confirm. Do the calendar list and Home's meetings "
                    + "disappear, with Home showing “Connect Microsoft 365 "
                    + "to see upcoming meetings”? Connect again afterwards: "
                    + "does everything come back, with your calendar "
                    + "choices kept?"
            )
        ]
    )
}
