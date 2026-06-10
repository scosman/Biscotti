#if DEBUG
    import AppCore
    import DataStore
    import Foundation

    extension MeetingListViewModel {
        /// Creates a preview-ready view model.
        ///
        /// Note: this preview helper uses a stripped-down AppCore with an
        /// in-memory store. The view model projects from `core.summaries`,
        /// which starts empty. SwiftUI previews primarily verify layout,
        /// not data.
        @MainActor
        static func preview() -> MeetingListViewModel {
            let core = try! PreviewAppCore.make() // swiftlint:disable:this force_try
            return MeetingListViewModel(core: core)
        }
    }
#endif
