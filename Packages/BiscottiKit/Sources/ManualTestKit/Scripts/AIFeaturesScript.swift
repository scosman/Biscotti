/// The AI Features manual test script.
///
/// Covers the end-to-end app-level AI features built by the `llm_features`
/// spec project: model download in Settings, auto speaker-ID + streamed
/// summary after transcription, summary editing + regeneration, and manual
/// speaker renaming via the mapping sheet. All steps run in the full
/// Biscotti app (not ManualTestApp) and require a real meeting recording.
public extension TestScript {
    /// AI Features test script — covers Settings AI section, auto-run
    /// (speaker-ID + summary), summary editing/regeneration, and manual
    /// speaker mapping.
    static let aiFeatures = TestScript(
        id: "ai_features",
        title: "AI Features",
        steps: [
            // -- Setup --
            .instruction(
                id: "ai_setup",
                text: "These tests run in the full Biscotti app. Launch the app, "
                    + "open Settings, and navigate to the 'AI Enhancements' section. "
                    + "If the model is already downloaded, skip the download steps."
            ),

            // -- Settings: AI Enhancements --
            .humanQuestion(
                id: "ai_settings_section",
                prompt: "In Settings, is there an 'AI Enhancements' section with two "
                    + "toggles ('Summarize Transcripts' and 'Guess Speaker Names') and "
                    + "a subtitle 'AI runs locally on your Mac'?"
            ),
            .humanQuestion(
                id: "ai_settings_no_model",
                prompt: "If no model is downloaded: are both toggles disabled and shown "
                    + "as off, with a 'Download Local Language AI Model?' row and a "
                    + "Download button? (If the model is already downloaded, mark Pass "
                    + "and move on.)"
            ),
            .humanQuestion(
                id: "ai_model_download",
                prompt: "Press Download. Does the download show progress (percentage / "
                    + "bytes)? When complete, do the toggles become enabled and reflect "
                    + "their stored values (default: both on)?"
            ),
            .humanQuestion(
                id: "ai_toggles_persist",
                prompt: "Toggle both settings off, close and reopen Settings. Are both "
                    + "still off? Toggle them back on and confirm they persist."
            ),

            // -- Record and transcribe --
            .instruction(
                id: "ai_record_setup",
                text: "Ensure both AI toggles are ON in Settings. Start a recording "
                    + "(join a real or test meeting with at least 2 speakers for 30+ "
                    + "seconds), then stop recording and wait for transcription to "
                    + "complete."
            ),

            // -- Auto-run: speaker identification --
            .humanQuestion(
                id: "ai_auto_speaker_id",
                prompt: "After transcription completes, observe the transcript tab. "
                    + "Do speaker labels change from 'Speaker 0/1/...' to real names "
                    + "(or at least some speakers are identified)? If the meeting had "
                    + "calendar invitees, are the identified names plausible?"
            ),

            // -- Auto-run: streamed summary --
            .humanQuestion(
                id: "ai_auto_summary_stream",
                prompt: "Switch to the Summary tab. Did the summary stream in "
                    + "(tokens appearing incrementally)? Is the final summary a "
                    + "coherent markdown document with meeting notes and an "
                    + "'Action Items' section?"
            ),
            .humanQuestion(
                id: "ai_summary_speaker_names",
                prompt: "Does the summary use the identified speaker names (not "
                    + "'Speaker 0/1/...')? (If speaker-ID found no names, 'Speaker N' "
                    + "labels in the summary are acceptable; mark Pass.)"
            ),

            // -- Summary editing --
            .humanQuestion(
                id: "ai_summary_edit",
                prompt: "Edit the summary text (add or change a word). Does the edit "
                    + "save automatically (close and reopen the meeting to confirm)?"
            ),

            // -- Regenerate summary --
            .humanQuestion(
                id: "ai_regenerate_edited_confirm",
                prompt: "With the edited summary, open the '...' overflow menu and "
                    + "tap 'Regenerate Summary'. Does a confirmation dialog appear "
                    + "warning that your edited summary will be replaced?"
            ),
            .humanQuestion(
                id: "ai_regenerate_result",
                prompt: "Confirm the regeneration. Does a new summary stream in, "
                    + "replacing the edited version? Is the new summary coherent?"
            ),
            .humanQuestion(
                id: "ai_regenerate_no_confirm",
                prompt: "Without editing the regenerated summary, tap 'Regenerate "
                    + "Summary' again from the overflow menu. Does it regenerate "
                    + "immediately WITHOUT a confirmation dialog (since the summary "
                    + "is AI-generated, not human-edited)?"
            ),

            // -- Manual speaker mapping (with model) --
            .humanQuestion(
                id: "ai_speaker_link_opens_sheet",
                prompt: "In the Transcript tab, click on a speaker name/label. Does "
                    + "a speaker mapping sheet open showing all speakers with their "
                    + "current assignments?"
            ),
            .humanQuestion(
                id: "ai_manual_rename",
                prompt: "In the mapping sheet, manually assign a different person to "
                    + "a speaker (pick from the dropdown or add a new name). Does the "
                    + "transcript update to show the new name?"
            ),
            .humanQuestion(
                id: "ai_manual_unassign",
                prompt: "In the mapping sheet, set a speaker to 'Unassigned'. Does "
                    + "the transcript revert that speaker to 'Speaker N'?"
            ),

            // -- Model-free manual assignment --
            .instruction(
                id: "ai_model_free_setup",
                text: "To test model-free speaker assignment: go to Settings and "
                    + "turn OFF both AI toggles. Create a new recording (short, 10+ "
                    + "seconds with speech), stop, and wait for transcription."
            ),
            .humanQuestion(
                id: "ai_model_free_no_auto",
                prompt: "After transcription with AI toggles off: is there no auto "
                    + "speaker identification (speakers show as 'Speaker 0/1/...')? "
                    + "Is the Summary tab empty with a hint pointing to Settings?"
            ),
            .humanQuestion(
                id: "ai_model_free_manual",
                prompt: "Click a speaker label to open the mapping sheet. Can you "
                    + "still manually assign names without the model? Does the "
                    + "transcript update to show the assigned name?"
            ),

            // -- Summary empty states --
            .humanQuestion(
                id: "ai_summary_empty_generate",
                prompt: "With AI toggles back ON and the model downloaded, view a "
                    + "meeting that has a transcript but no summary. Does the Summary "
                    + "tab show a 'Generate Summary' button? Press it — does a "
                    + "summary stream in?"
            ),

            // -- Status indicator --
            .humanQuestion(
                id: "ai_status_indicator",
                prompt: "During an auto-run (after a new transcription), is there a "
                    + "subtle processing indicator visible (e.g. in the Summary tab "
                    + "header or meeting row) showing AI work is in progress?"
            )
        ]
    )
}
