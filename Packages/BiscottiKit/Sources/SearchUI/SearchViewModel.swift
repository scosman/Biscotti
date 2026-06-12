import AppCore
import DataStore
import Foundation

/// View model for the search results screen.
///
/// Provides live-filtered search with debounce, ranked results from
/// `DataStore.searchHits`, and back-restore via `AppCore.dismissSearch`.
@MainActor @Observable
public final class SearchViewModel {
    private let core: AppCore

    /// The current search query. Set by `updateQuery(_:)`.
    public private(set) var query: String = ""

    /// The search results, ranked by score.
    public private(set) var results: [SearchHit] = []

    /// Whether a search query is in progress.
    public private(set) var isSearching: Bool = false

    /// Monotonic counter incremented when the search field should lose focus.
    /// AppShellView observes this via `.onChange` and sets its `@FocusState`
    /// to `false`. Using a counter (not a bool) avoids coalescing rapid signals.
    public private(set) var dismissFocusCount: Int = 0

    private var searchTask: Task<Void, Never>?

    public init(core: AppCore) {
        self.core = core
    }

    // MARK: - Derived

    /// Whether to show the "no results" empty state.
    public var showNoResults: Bool {
        !query.isEmpty && results.isEmpty && !isSearching
    }

    /// The message for the no-results state.
    public var noResultsMessage: String {
        "No meetings match '\(query)'."
    }

    // MARK: - Actions

    /// Called when the search query changes. Debounces 300ms before
    /// running the actual search, cancelling any prior in-flight query.
    public func updateQuery(_ newQuery: String) {
        query = newQuery
        debounceAndSearch()
    }

    /// Re-activates the search takeover for the current query without
    /// requiring a text change. Used when the user presses Enter/submit
    /// or re-focuses the search field after navigating away from results.
    ///
    /// Does nothing if the query is empty. If the search pane is already
    /// active, refreshes results for the current query.
    public func reactivateSearch() {
        guard !query.isEmpty else { return }
        core.presentSearch()
        searchImmediately()
    }

    /// Called when the user selects a search result. Opens meeting detail.
    public func selectResult(_ meetingID: UUID) {
        dismissFocusCount += 1
        core.select(meetingID)
    }

    /// Called when the user taps Back. Restores the pre-search route.
    public func dismiss() {
        dismissFocusCount += 1
        core.dismissSearch()
    }

    /// Called when the user taps the search page background (non-interactive area).
    /// Signals focus dismissal without navigating.
    public func dismissFocus() {
        dismissFocusCount += 1
    }

    // MARK: - Formatting

    /// A human-readable description of which fields matched.
    public nonisolated static func matchedFieldsText(
        _ fields: [SearchField]
    ) -> String {
        fields.map { field in
            switch field {
            case .title: "title"
            case .people: "people"
            case .transcript: "transcript"
            case .notes: "notes"
            }
        }.joined(separator: ", ")
    }

    // MARK: - Private

    /// Runs the search for the current query immediately (no debounce).
    /// Cancels any prior in-flight search task.
    private func searchImmediately() {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let currentQuery = query
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let hits = try await core.store.searchHits(
                    currentQuery, limit: 50
                )
                guard !Task.isCancelled else { return }
                results = hits
            } catch {
                guard !Task.isCancelled else { return }
                results = []
            }
            isSearching = false
        }
    }

    private func debounceAndSearch() {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        // Clear stale results and show spinner immediately on query change,
        // before the debounce fires. This prevents showing outdated results
        // while the user is still typing.
        results = []
        isSearching = true
        let currentQuery = query
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let self,
                  query == currentQuery
            else { return }
            do {
                let hits = try await core.store.searchHits(
                    currentQuery, limit: 50
                )
                guard !Task.isCancelled else { return }
                results = hits
            } catch {
                guard !Task.isCancelled else { return }
                results = []
            }
            isSearching = false
        }
    }
}
