/// The App URLs manual test script.
///
/// Opens real `biscotti://` URLs through the system (ManualTestApp is a
/// separate bundle, so macOS routes them to the real Biscotti app) and
/// has the human confirm where Biscotti landed. The action closures are
/// placeholder no-ops here — the app target substitutes
/// `NSWorkspace.open` and pasteboard reads when it builds the runner.
///
/// The meeting steps get a real UUID from the pasteboard: the human uses
/// the real app's Copy Meeting Link command first, which also exercises
/// that menu item end to end. The delivery-state steps (cold launch,
/// menu-bar only, background) open their URLs with wired buttons like
/// every other route — ManualTestApp is itself an external caller, so
/// they exercise the same delivery path any integrator would.
public extension TestScript {
    static let appURLs = TestScript(
        id: "app_urls",
        title: "App URLs",
        steps: [
            // Setup instruction (passive text)
            .instruction(
                id: "au_setup",
                text: "The real Biscotti app (not ManualTestApp) must be "
                    + "the build you are testing, registered with "
                    + "LaunchServices, and past onboarding — URLs are "
                    + "dropped while onboarding is showing. If a stale "
                    + "Biscotti build is registered, URLs open THAT build: "
                    + "launch the current build from Xcode once before "
                    + "running this script."
            ),
            // Fixed routes: one action + one question each
            .action(
                id: "au_open_home",
                label: "Open biscotti://home",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_home_landed",
                prompt: "Did Biscotti come to the front on the Home screen?"
            ),
            .action(
                id: "au_open_meetings",
                label: "Open biscotti://meetings",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_meetings_landed",
                prompt: "Meetings screen in browse mode — any active search "
                    + "cleared, previous selection kept?"
            ),
            .action(
                id: "au_open_settings",
                label: "Open biscotti://settings",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_settings_landed",
                prompt: "Settings open at its default section?"
            ),
            .action(
                id: "au_open_search",
                label: "Open biscotti://search?query= (empty query)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_search_focused",
                prompt: "Meetings screen with an empty query (browse mode) "
                    + "and the search field focused, cursor in it?"
            ),
            .action(
                id: "au_open_search_query",
                label: "Open biscotti://search?query=meeting",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_search_filtered",
                prompt: "Search field populated with the term 'meeting', "
                    + "the search ran, and the list is filtered to "
                    + "matches (no-results is fine if nothing matches)?"
            ),
            // record — starts a REAL recording
            .instruction(
                id: "au_record_setup",
                text: "The next step starts a REAL recording through the "
                    + "URL — the same startup path as the ⌘⇧R hotkey, "
                    + "permissions included. After answering the question, "
                    + "stop the recording."
            ),
            .action(
                id: "au_open_record",
                label: "Open biscotti://record",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_record_started",
                prompt: "Recording pane shown with a live recording? Stop "
                    + "it now — does the new meeting appear afterwards?"
            ),
            // Meeting routes — UUID comes from the pasteboard
            .instruction(
                id: "au_copy_link_setup",
                text: "In the real Biscotti app: right-click a meeting in "
                    + "the Meetings list (single selection) and choose "
                    + "Copy Meeting Link. This also exercises that menu "
                    + "item. The next three steps read the link from the "
                    + "pasteboard. Pick a meeting with a transcript, so "
                    + "the ?time= step has somewhere to seek."
            ),
            .action(
                id: "au_open_meeting",
                label: "Open the copied meeting link as-is",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_meeting_summary",
                prompt: "Did the linked meeting open on its Summary tab?"
            ),
            .action(
                id: "au_open_meeting_notes",
                label: "Open the same link with ?tab=notes",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_meeting_notes_landed",
                prompt: "Same meeting, Notes tab shown (no seek)?"
            ),
            .action(
                id: "au_open_meeting_time",
                label: "Open the same link with ?time=30",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_meeting_time_seek",
                prompt: "Transcript tab with playback cued to ~30 seconds?"
            ),
            // Delivery states unit tests cannot reach
            .instruction(
                id: "au_cold_launch_setup",
                text: "Quit Biscotti completely via the Quit item in its "
                    + "menu-bar menu (Biscotti ▸ Quit Biscotti). Note: "
                    + "with the default settings, ⌘Q is NOT a full quit — "
                    + "Biscotti catches it and stays running in the menu "
                    + "bar with the window closed. The next step opens "
                    + "the meeting link you copied earlier, so leave it "
                    + "on the pasteboard."
            ),
            .action(
                id: "au_cold_launch_open",
                label: "Open the copied meeting link (Biscotti not running)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_cold_launch_check",
                prompt: "Did Biscotti launch from quit and open the linked "
                    + "meeting on its Summary tab?"
            ),
            .instruction(
                id: "au_menubar_setup",
                text: "Close Biscotti's window with the red traffic-light "
                    + "button (the app stays alive in the menu bar)."
            ),
            .action(
                id: "au_menubar_open",
                label: "Open biscotti://meetings (window closed)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_menubar_check",
                prompt: "Did Biscotti's window re-open on Meetings?"
            ),
            .instruction(
                id: "au_background_setup",
                text: "Bring another app in front of Biscotti (Biscotti "
                    + "still running with its window)."
            ),
            .action(
                id: "au_background_open",
                label: "Open biscotti://home (Biscotti in the background)",
                run: { _ in /* wired by the app target */ }
            ),
            .humanQuestion(
                id: "au_background_check",
                prompt: "Did Biscotti come to the front on Home?"
            )
        ]
    )
}
