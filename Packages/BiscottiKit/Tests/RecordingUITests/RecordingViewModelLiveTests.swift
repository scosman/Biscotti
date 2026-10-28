import AppCore
import BiscottiTestSupport
import Foundation
import LiveTranscriptionService
import LiveTranscriptModel
import Recording
import Testing
import TranscriptUI
@testable import RecordingUI

/// A recording screen whose core runs a fake live engine.
@MainActor
private struct LiveScreenFixture {
    let fix: CoreFixture
    let engines = FakeLiveEngineFactory()
    let model: FakeLiveModel
    let live: LiveTranscriptionService
    let viewModel: RecordingViewModel
    let copied = CopiedText()

    init(isEnabled: Bool = true, modelPresent: Bool = true, macLanguageCode: String = "en") throws {
        model = FakeLiveModel(present: modelPresent)
        // The fake recorder never closes its tap, so a finish after Stop runs
        // into the stop deadline, kept short here.
        live = makeFakeLiveService(
            engines: engines,
            model: model,
            isEnabled: isEnabled,
            macLanguageCode: macLanguageCode,
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        fix = try makeCoreFixture(liveTranscription: live, testName: "RecordingViewModelLiveTests")
        let copied = copied
        viewModel = RecordingViewModel(core: fix.core, copyToPasteboard: { copied.text = $0 })
    }

    func runningEngine() async throws -> FakeLiveEngine {
        try await waitUntil("a live engine") { engines.engines.count == 1 }
        let engine = engines.engines[0]
        try await waitUntil("its config") { await engine.config != nil }
        return engine
    }

    func stop() async {
        _ = await fix.core.stopRecording()
        await fix.core.awaitPendingTranscription()
        fix.cleanup()
    }
}

private final class CopiedText {
    var text: String?
}

@Suite("RecordingViewModel -- live transcript")
@MainActor
struct RecordingViewModelLiveTests {
    @Test("The toggle and drawer are hidden while live transcription is off")
    func overlayHiddenWhenLiveOff() async throws {
        let ctx = try LiveScreenFixture(isEnabled: false)
        await ctx.fix.core.startRecording()
        #expect(!ctx.viewModel.showsLiveTranscript)

        await ctx.live.setEnabled(true)
        #expect(ctx.viewModel.showsLiveTranscript)
        #expect(ctx.viewModel.liveStatus == .starting)
        await ctx.stop()
    }

    @Test("Each status has its text beside the toggle; Live has none, and Catching up shows in the header instead")
    func statusTextMatchesEachStatus() {
        let cases: [(LiveStatus, String?)] = [
            (.off, nil),
            (.live, nil),
            (.starting, "Starting"),
            (.catchingUp, nil),
            (.paused(.lowPowerHeat), "Paused while the Mac cools down"),
            (.unavailable(.modelMissing), "Needs the transcription model"),
            (.unavailable(.languageUnsupported), "Not available for this language"),
            (.unavailable(.stopped), "Live transcript stopped")
        ]
        for (status, text) in cases {
            #expect(RecordingViewModel.statusText(for: status) == text, "\(status)")
        }
    }

    @Test("VoiceOver names each state of the toggle")
    func accessibilityValueNamesEachState() {
        #expect(RecordingViewModel.accessibilityValue(for: .live) == "Live")
        #expect(RecordingViewModel.accessibilityValue(for: .starting) == "Starting")
        #expect(RecordingViewModel.accessibilityValue(for: .catchingUp) == "Catching up")
        #expect(RecordingViewModel.accessibilityValue(for: .paused(.lowPowerHeat)) == "Paused")
        #expect(RecordingViewModel.accessibilityValue(for: .unavailable(.stopped)) == "Unavailable")
        #expect(LiveToggleButton.tooltip(isExpanded: false, status: .live) == "Show transcript (\u{2318}T)")
        #expect(LiveToggleButton.tooltip(isExpanded: true, status: .unavailable(.modelMissing))
            == "Needs the transcription model. Hide transcript (\u{2318}T)")
    }

    @Test("A note's time opens the drawer at the note's moment on the recording timeline")
    func revealAddsTimelineOffsetToNoteTime() async throws {
        let ctx = try LiveScreenFixture()
        ctx.fix.fakeRecorder.backing.timelineOffset = 0.75
        await ctx.fix.core.startRecording()
        #expect(!ctx.viewModel.isDrawerExpanded)

        ctx.viewModel.revealNoteInTranscript(MeetingNote(text: "Ship it", timestamp: 50))
        #expect(ctx.viewModel.revealTime == 50.75)
        #expect(ctx.viewModel.isDrawerExpanded)

        ctx.viewModel.revealTime = nil
        #expect(ctx.live.revealRequest == nil, "the list scrolled, so the request is handled")
        await ctx.stop()
    }

    @Test("Revealing a note expands a collapsed drawer and keeps an open one open")
    func revealExpandsDrawer() async throws {
        let ctx = try LiveScreenFixture()
        await ctx.fix.core.startRecording()
        ctx.viewModel.revealNoteInTranscript(MeetingNote(text: "One", timestamp: 1))
        #expect(ctx.viewModel.isDrawerExpanded)
        ctx.viewModel.revealNoteInTranscript(MeetingNote(text: "Two", timestamp: 2))
        #expect(ctx.viewModel.isDrawerExpanded)
        ctx.viewModel.collapseDrawer()
        #expect(!ctx.viewModel.isDrawerExpanded)
        await ctx.stop()
    }

    @Test("Copy puts one line per bubble on the pasteboard, prefixed You or Others")
    func copyLivePrefixesYouAndOthers() async throws {
        let ctx = try LiveScreenFixture()
        await ctx.fix.core.startRecording()
        #expect(!ctx.viewModel.canCopyLiveTranscript)
        let engine = try await ctx.runningEngine()
        let mine = LiveRow(track: .mic, startTime: 0, endTime: 1, settledText: "Is the fix in?")
        let theirs = LiveRow(track: .system, startTime: 1, endTime: 2, settledText: "Yes,", tailText: " it is")
        await engine.emit(liveUpdate(.mic, rows: [mine], transcribedThrough: 1, settledThrough: 1))
        await engine.emit(liveUpdate(.system, rows: [theirs], transcribedThrough: 2, settledThrough: 1.5))
        try await waitUntil("both rows") { ctx.live.rows.count == 2 }

        #expect(ctx.viewModel.canCopyLiveTranscript)
        ctx.viewModel.copyLiveTranscript()
        #expect(ctx.copied.text == "You: Is the fix in?\nOthers: Yes, it is")
        await ctx.stop()
    }

    @Test("The drawer's bubbles have no labels and follow new rows")
    func liveItemsHaveNoLabelsAndFollowNewRows() async throws {
        let ctx = try LiveScreenFixture()
        await ctx.fix.core.startRecording()
        let engine = try await ctx.runningEngine()
        let first = LiveRow(track: .mic, startTime: 0, endTime: 1, settledText: "Hello")
        await engine.emit(liveUpdate(.mic, rows: [first], transcribedThrough: 1, settledThrough: 1))
        try await waitUntil("the row") { !ctx.live.rows.isEmpty }
        let before = ctx.viewModel.liveItems
        #expect(before.count == 1 && before[0].bubble?.label == nil)
        // An unchanged live state returns the cached array itself, not a rebuild.
        #expect(Self.storage(of: ctx.viewModel.liveItems) == Self.storage(of: before))

        let second = LiveRow(track: .system, startTime: 1, endTime: 2, settledText: "Hi")
        await engine.emit(liveUpdate(.system, rows: [second], transcribedThrough: 2, settledThrough: 2))
        try await waitUntil("the second row") { ctx.live.rows.count == 2 }
        let after = ctx.viewModel.liveItems
        #expect(Self.storage(of: after) != Self.storage(of: before), "new rows rebuild the items")
        #expect(after.map(\.id) == [first.id.uuidString, second.id.uuidString])
        #expect(ctx.viewModel.liveItems.allSatisfy { $0.bubble?.label == nil })
        await ctx.stop()
    }

    /// The address of an array's buffer: equal only for the same storage.
    private static func storage(of items: [TranscriptItem]) -> UnsafeRawPointer? {
        items.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    @Test("The slow-start note waits 10 s from when Starting began")
    func slowStartCountsFromStartingBegan() {
        let now = Date()
        #expect(!LiveTranscriptDrawer.isSlowStart(since: nil, now: now))
        #expect(!LiveTranscriptDrawer.isSlowStart(since: now.addingTimeInterval(-9), now: now))
        #expect(LiveTranscriptDrawer.isSlowStart(since: now.addingTimeInterval(-10), now: now))
    }

    @Test("A slow live start blames the disk only when it is low")
    func slowStartMessagesFollowTheDisk() {
        let low = RecordingViewModel.slowStartMessages(lowOnDisk: true)
        #expect(low.first == "Your Mac is low on disk space, so macOS removed the prepared speech model.")
        #expect(low.last?.hasSuffix("The transcript will catch up from the start.") == true)
        let other = RecordingViewModel.slowStartMessages(lowOnDisk: false)
        #expect(other.first == "Preparing the speech model.")
        #expect(!other.joined().contains("disk"))
    }

    @Test("The language menu shows the language Detect found")
    func languageMenuShowsDetectedLanguage() async throws {
        let ctx = try LiveScreenFixture(macLanguageCode: "fr")
        await ctx.fix.core.startRecording()
        #expect(ctx.viewModel.liveLanguage == .detect)
        #expect(ctx.viewModel.languageMenuTitle == "Detect language")
        let engine = try await ctx.runningEngine()
        let row = LiveRow(track: .system, startTime: 0, endTime: 1, settledText: "Bonjour")
        await engine.emit(liveUpdate(.system, rows: [row], transcribedThrough: 1, settledThrough: 1, detectedLanguage: "fr"))
        try await waitUntil("the detected language") { ctx.viewModel.detectedLanguageName != nil }

        let french = try #require(Locale.current.localizedString(forLanguageCode: "fr"))
        #expect(ctx.viewModel.languageMenuTitle == french)

        await ctx.viewModel.setLanguage(.english)
        #expect(ctx.viewModel.languageMenuTitle == "English")
        await ctx.stop()
    }

    @Test("Whisper offers English and Detect; a kept language is named by its locale")
    func languageMenuOffersEnglishAndDetect() {
        let whisper = RecordingViewModel.whisperLanguageChoices
        #expect(whisper.map(\.language) == [.english, .detect])
        #expect(whisper.map(\.subtitle) == ["Best quality", "Finds the language once, then keeps it"])
        #expect(RecordingViewModel.languageTitle(language: .locale("fr-FR"), detectedName: nil)
            == Locale.current.localizedString(forIdentifier: "fr-FR"))
    }

    @Test("Without the model the drawer offers the download, and live transcription starts after it")
    func downloadFromDrawerStartsLive() async throws {
        let ctx = try LiveScreenFixture(modelPresent: false)
        await ctx.fix.core.startRecording()
        #expect(ctx.viewModel.liveStatus == .unavailable(.modelMissing))
        #expect(ctx.viewModel.liveStatusText == "Needs the transcription model")
        #expect(ctx.viewModel.liveModelState == .missing)

        await ctx.viewModel.downloadLiveModel()
        #expect(ctx.viewModel.liveModelState == .ready)
        _ = try await ctx.runningEngine()
        #expect(ctx.viewModel.liveStatus == .starting)
        await ctx.stop()
    }

    @Test("The drawer takes 45% of the height, within 240 to 520 pt; the notes scroll clear of it")
    func drawerMetrics() {
        #expect(LiveTranscriptOverlay.drawerHeight(forAvailableHeight: 400) == 240)
        #expect(LiveTranscriptOverlay.drawerHeight(forAvailableHeight: 800) == 360)
        #expect(LiveTranscriptOverlay.drawerHeight(forAvailableHeight: 2000) == 520)
        #expect(LiveTranscriptOverlay.notesBottomInset(showsLive: false, isExpanded: true, drawerHeight: 300) == 0)
        #expect(LiveTranscriptOverlay.notesBottomInset(showsLive: true, isExpanded: false, drawerHeight: 300) == 60)
        #expect(LiveTranscriptOverlay.notesBottomInset(showsLive: true, isExpanded: true, drawerHeight: 300) == 316)
    }

    @Test("The drawer spans the window less a 16 pt gutter on each side, at most 880 pt")
    func drawerWidthSpansWindowUpTo880() {
        #expect(LiveTranscriptOverlay.drawerWidth(forAvailableWidth: 640) == 608)
        #expect(LiveTranscriptOverlay.drawerWidth(forAvailableWidth: 890) == 858)
        #expect(LiveTranscriptOverlay.drawerWidth(forAvailableWidth: 1400) == 880)
    }

    @Test("Opening the drawer moves the notes up just enough to keep the note field 16 pt above it")
    func notesMoveUpToKeepTheNoteFieldAboveTheDrawer() {
        // A 640 pt screen opens a 288 pt drawer whose top is at 336 pt; the note field ends 16 pt above.
        #expect(LiveTranscriptOverlay.notesOffset(noteFieldBottom: 400, viewportHeight: 640, drawerHeight: 288) == 80)
        #expect(LiveTranscriptOverlay.notesOffset(noteFieldBottom: 320, viewportHeight: 640, drawerHeight: 288) == 0)
        #expect(LiveTranscriptOverlay.notesOffset(noteFieldBottom: 200, viewportHeight: 640, drawerHeight: 288) == 0)
    }

    // The column's top (Stop & Save) is 303 pt above the note field's bottom in each case.

    @Test("With room for both, the drawer keeps its height and the note field sits above it")
    func openLayoutWithRoomKeepsTheDrawerHeight() {
        let layout = LiveTranscriptOverlay.openLayout(viewportHeight: 700, headerTop: 150, noteFieldBottom: 453)
        #expect(layout == .init(drawerHeight: 315, notesOffset: 100))
    }

    @Test("A shorter window shrinks the drawer so Stop & Save and the note field both fit above it")
    func openLayoutShrinksTheDrawerToKeepStopAndSaveInView() {
        let layout = LiveTranscriptOverlay.openLayout(viewportHeight: 600, headerTop: 100, noteFieldBottom: 403)
        // The drawer top is at 335 pt; the note field ends 16 pt above it; Stop & Save sits 16 pt from the top.
        #expect(layout == .init(drawerHeight: 249, notesOffset: 84))
    }

    @Test("When even a 240 pt drawer leaves no room, Stop & Save stays in view and the drawer covers the note field")
    func openLayoutKeepsStopAndSaveInViewInAShortWindow() {
        let layout = LiveTranscriptOverlay.openLayout(viewportHeight: 400, headerTop: 40, noteFieldBottom: 343)
        #expect(layout == .init(drawerHeight: 240, notesOffset: 24))
    }

    // The status row is 34 pt tall; the most a drawer may take in a 700 pt
    // viewport is 700 - 16 (gutter) - 16 (gap) - 34 - 16 (top margin) = 618 pt.

    @Test("A dragged height is kept between 240 pt and the height that leaves Stop & Save in view")
    func chosenHeightStaysWithinLimits() {
        func layout(_ preferred: CGFloat) -> LiveTranscriptOverlay.OpenLayout {
            LiveTranscriptOverlay.openLayout(
                viewportHeight: 700, headerTop: 150, noteFieldBottom: 453, firstRowsHeight: 34, preferredHeight: preferred
            )
        }
        #expect(LiveTranscriptOverlay.maximumDrawerHeight(viewportHeight: 700, firstRowsHeight: 34) == 618)
        #expect(layout(1000) == .init(drawerHeight: 618, notesOffset: 134), "the status row ends 16 pt above the drawer")
        #expect(layout(100) == .init(drawerHeight: 240, notesOffset: 25))
        // A tall drawer covers the note field rather than Stop & Save.
        #expect(layout(400) == .init(drawerHeight: 400, notesOffset: 134))
        #expect(LiveTranscriptOverlay.maximumDrawerHeight(viewportHeight: 300, firstRowsHeight: 34) == 240)
    }

    @Test("A dragged height is saved in whole points; double-click restores the default, which fits the window")
    func chosenHeightSavesAndResets() throws {
        let ctx = try LiveScreenFixture()
        defer { ctx.fix.cleanup() }
        #expect(ctx.viewModel.liveDrawerHeight == nil)
        ctx.viewModel.setLiveDrawerHeight(412.4)
        #expect(ctx.live.drawerHeight == 412)
        #expect(ctx.viewModel.liveDrawerHeight == 412)
        ctx.viewModel.resetLiveDrawerHeight()
        #expect(ctx.live.drawerHeight == nil)
        let fitted = LiveTranscriptOverlay.openLayout(viewportHeight: 600, headerTop: 100, noteFieldBottom: 403, firstRowsHeight: 34)
        #expect(fitted == .init(drawerHeight: 249, notesOffset: 84), "the default still shrinks to fit")
    }

    @Test("The header shows Catching up only while the live text is behind")
    func headerShowsCatchingUp() throws {
        #expect(RecordingViewModel.catchingUpText == "Catching up…")
        #expect(RecordingViewModel.showsCatchingUp(for: .catchingUp))
        let others: [LiveStatus] = [.off, .starting, .live, .paused(.lowPowerHeat), .unavailable(.stopped)]
        #expect(others.allSatisfy { !RecordingViewModel.showsCatchingUp(for: $0) })
        let ctx = try LiveScreenFixture()
        defer { ctx.fix.cleanup() }
        #expect(!ctx.viewModel.isLiveCatchingUp, "Off before a recording")
    }

    @Test("Still bars sit at a steady mid height; moving bars stay within 6 to 16 pt")
    func levelMeterHeights() {
        let still = LevelMeter.barHeights(level: nil)
        #expect(still.count == 4)
        #expect(still.allSatisfy { $0 > LevelMeter.minHeight && $0 < LevelMeter.maxHeight })
        let silent = LevelMeter.barHeights(level: 0)
        let loud = LevelMeter.barHeights(level: 1)
        #expect(silent.allSatisfy { $0 >= LevelMeter.minHeight && $0 < 8 })
        #expect(loud.max() == LevelMeter.maxHeight)
        #expect(zip(silent, loud).allSatisfy { $0 < $1 })
    }
}
