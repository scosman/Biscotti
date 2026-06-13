#if DEBUG
    import AppCore
    import DataStore
    import Foundation

    extension MeetingListViewModel {
        /// Creates a preview-ready view model with an empty store (browse empty).
        @MainActor
        static func previewEmpty() -> MeetingListViewModel {
            let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
            return MeetingListViewModel(core: core)
        }

        /// Creates a preview-ready view model with pre-populated meetings
        /// (browse mode, grouped list). Summaries are set synchronously so
        /// they are visible on the very first render.
        @MainActor
        static func previewBrowse() -> MeetingListViewModel {
            let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
            let now = Date()
            core.summaries = [
                MeetingSummary(
                    id: UUID(), title: "Design Review",
                    date: now, hasTranscript: true
                ),
                MeetingSummary(
                    id: UUID(), title: "Sprint Planning",
                    date: now.addingTimeInterval(-86400),
                    hasTranscript: false
                ),
                MeetingSummary(
                    id: UUID(), title: "1:1 with Sam",
                    date: now.addingTimeInterval(-604_800),
                    hasTranscript: true
                )
            ]
            return MeetingListViewModel(core: core)
        }

        /// Creates a preview-ready view model in search mode
        /// (query set, results pending).
        @MainActor
        static func previewSearch() -> MeetingListViewModel {
            let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
            // Set a query to switch to search mode. Results will be
            // empty (debounce + in-memory store), showing the spinner
            // or no-results state.
            core.setMeetingsQuery("budget")
            return MeetingListViewModel(core: core)
        }
    }
#endif
