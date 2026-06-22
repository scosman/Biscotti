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

            // -- Pipeline status control (Phase 7 polish) --
            .humanQuestion(
                id: "ai_pipeline_status",
                prompt: "After stopping a new recording, switch to the Summary tab. "
                    + "Does a pipeline status control appear showing ordered stages "
                    + "(e.g. 'Transcribing → Inferring participant names → "
                    + "Summarizing') with done/active/pending indicators? Is it "
                    + "shown in place of 'No transcript available.'?"
            ),
            .humanQuestion(
                id: "ai_pipeline_auto_jump",
                prompt: "When the processing pipeline activates for the open meeting, "
                    + "does the detail view automatically switch to the Summary tab "
                    + "(so the pipeline status is visible)? Confirm it only jumps "
                    + "once and does not fight subsequent manual tab changes."
            ),
            .humanQuestion(
                id: "ai_pipeline_gating",
                prompt: "With 'Guess Speaker Names' OFF (but model present and "
                    + "'Summarize Transcripts' ON), start a new recording/transcription. "
                    + "Does the pipeline status omit the 'Inferring participant names' "
                    + "stage (showing only Transcribing → Summarizing)?"
            ),
            .humanQuestion(
                id: "ai_pipeline_no_pill",
                prompt: "While the pipeline is active, confirm there is NO trailing "
                    + "pill/badge in the tab bar row (the old 'Enhancing...' pill from "
                    + "earlier designs should be gone)."
            ),

            // -- Re-transcribe re-runs AI (Phase 7 polish) --
            .instruction(
                id: "ai_retranscribe_setup",
                text: "Ensure both AI toggles are ON and a model is downloaded. Open a "
                    + "meeting that already has a transcript and AI-generated summary. "
                    + "Use the '...' overflow menu to tap 'Re-transcribe'."
            ),
            .humanQuestion(
                id: "ai_retranscribe_reruns",
                prompt: "After re-transcribing, does the AI auto-run fire again "
                    + "(pipeline status appears, then speaker-ID + summary re-run)? "
                    + "Does the new summary reflect the re-transcribed content?"
            ),

            // -- Summary completion: no flash / scroll (Phase 8 polish) --
            .humanQuestion(
                id: "ai_summary_no_flash",
                prompt: "Watch carefully as a streamed summary finishes (last token). "
                    + "Does the view transition smoothly to the editable summary "
                    + "WITHOUT flashing to an empty/Generate state? The content "
                    + "should stay visible continuously."
            ),
            .humanQuestion(
                id: "ai_summary_scroll_retained",
                prompt: "During summary streaming, scroll down in the Summary tab so "
                    + "the top is not visible. When streaming completes, is your "
                    + "scroll position retained (not reset to top)?"
            ),

            // -- Settings layout (Phase 9 polish) --
            .humanQuestion(
                id: "ai_settings_header_caption",
                prompt: "In Settings, look at the 'AI Enhancements' section. Is 'AI "
                    + "runs locally on your Mac.' shown as muted/grey text trailing "
                    + "the section header (same line as the title), NOT as a section "
                    + "footer below the toggles?"
            ),
            .humanQuestion(
                id: "ai_settings_section_order",
                prompt: "Verify the Settings section order from top to bottom is: "
                    + "General → Permissions → AI Enhancements → Notifications → "
                    + "Calendars (with Debug last if present). Is Permissions the "
                    + "2nd section, immediately after General?"
            ),

            // -- Manual assignment survives re-run (Phase 10 polish) --
            .humanQuestion(
                id: "ai_userset_survives_rerun",
                prompt: "Manually assign a speaker to a specific person via the mapping "
                    + "sheet. Then re-transcribe (or trigger a new AI auto-run). After "
                    + "the AI run completes, does your manual assignment survive "
                    + "unchanged (the LLM did NOT overwrite it)?"
            ),

            // -- Merged speaker color (Phase 11 polish) --
            .humanQuestion(
                id: "ai_merged_speaker_color",
                prompt: "Assign two different speaker IDs (e.g. Speaker 0 and Speaker 2) "
                    + "to the SAME person via the mapping sheet. In the transcript, do "
                    + "both speakers now share one color? And does the mapping sheet's "
                    + "leading color dot also match for both?"
            ),
            .humanQuestion(
                id: "ai_unassigned_speaker_color",
                prompt: "Confirm that speakers that are NOT assigned to a person still "
                    + "have their own stable per-speaker-ID color (distinct from the "
                    + "merged color of assigned speakers)."
            )
        ]
    )
}
