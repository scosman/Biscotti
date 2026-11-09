import DataStore
import Foundation
import os

private let logger = Logger(
    subsystem: "net.scosman.biscotti", category: "AudioImport"
)

/// Session-long ordered import list, serial conversion worker, and meeting
/// creation. No AppKit, no SwiftUI.
@MainActor @Observable
// swiftlint:disable:next type_body_length
public final class AudioImportController {
    // MARK: - Published state

    public private(set) var items: [ImportItem] = []
    public private(set) var run: ImportRun?

    /// True when any item is receiving, waiting or converting.
    public var hasPendingWork: Bool {
        items.contains {
            switch $0.status {
            case .receiving, .waiting, .converting: true
            default: false
            }
        }
    }

    /// True while the worker is converting (drives the sidebar spinner).
    public var isConverting: Bool {
        items.contains { $0.status == .converting }
    }

    public var hasSession: Bool {
        !items.isEmpty
    }

    /// Index of the item currently converting within the current run (1-based),
    /// or nil.
    public var runPosition: Int? {
        guard let run else { return nil }
        guard let convertingIdx = items.firstIndex(where: {
            $0.status == .converting
        }) else { return nil }
        return convertingIdx - run.startIndex + 1
    }

    /// Called on the main actor after each item finishes (done or failed).
    @ObservationIgnored
    public var onItemFinished: (@MainActor (ImportFinished) async -> Void)?

    // MARK: - Private

    private let store: DataStore
    public let recordingsRoot: URL
    private let converter: any AudioConverting
    private let metadata: any ImportMetadataReading
    private let now: @Sendable () -> Date

    private var worker: Task<Void, Never>?
    private var deliveryTasks: [UUID: Task<URL, any Error>] = [:]
    private var dateTasks: [UUID: Task<Date?, Never>] = [:]
    private var batchSizes: [UUID: Int] = [:]
    private var finishedItems = Set<UUID>()

    /// Maximum time to wait for a promised file before marking it failed.
    let deliveryTimeout: Duration

    // MARK: - Init

    public init(
        store: DataStore,
        recordingsRoot: URL,
        converter: any AudioConverting = AVFoundationAudioConverter(),
        metadata: any ImportMetadataReading = AVFoundationMetadataReader(),
        now: @escaping @Sendable () -> Date = { Date() },
        deliveryTimeout: Duration = .seconds(15)
    ) {
        self.store = store
        self.recordingsRoot = recordingsRoot
        self.converter = converter
        self.metadata = metadata
        self.now = now
        self.deliveryTimeout = deliveryTimeout
    }

    // MARK: - Public API

    /// Appends entries (one import action) and starts the worker if idle.
    /// Returns the batch id.
    @discardableResult
    public func add(_ entries: [ImportEntry]) -> UUID {
        let batchID = UUID()
        guard !entries.isEmpty else { return batchID }

        let addedAt = now()
        batchSizes[batchID] = entries.count

        // Run tracking
        if !hasPendingWork {
            run = ImportRun(startIndex: items.count, count: entries.count)
        } else if run != nil {
            run?.count += entries.count
        } else {
            // Work is pending but no run (shouldn't happen, but be safe).
            let firstPendingIdx = items.firstIndex(where: {
                switch $0.status {
                case .receiving, .waiting, .converting: true
                default: false
                }
            }) ?? items.count
            run = ImportRun(
                startIndex: firstPendingIdx,
                count: entries.count
            )
        }

        for entry in entries {
            let itemID = UUID()
            switch entry {
            case let .file(url):
                let item = ImportItem(
                    id: itemID,
                    batchID: batchID,
                    displayName: url.lastPathComponent,
                    sourceURL: url,
                    status: .waiting,
                    addedAt: addedAt,
                    isPromised: false
                )
                items.append(item)
                startDateRead(itemID: itemID, url: url)

            case let .promised(displayName, deliver):
                let item = ImportItem(
                    id: itemID,
                    batchID: batchID,
                    displayName: displayName ?? "Incoming file",
                    status: .receiving,
                    addedAt: addedAt,
                    isPromised: true
                )
                items.append(item)
                startDelivery(itemID: itemID, deliver: deliver)
            }
        }

        startWorkerIfNeeded()
        return batchID
    }

    /// Removes `<recordingsRoot>/.import-staging` (crash leftovers).
    public nonisolated static func cleanStaging(recordingsRoot: URL) {
        let staging = recordingsRoot.appendingPathComponent(".import-staging")
        try? FileManager.default.removeItem(at: staging)
    }

    /// Test seam: returns once the queue is empty and idle.
    package func awaitIdle() async {
        while let current = worker {
            await current.value
        }
    }

    // MARK: - Delivery (promises)

    private func startDelivery(
        itemID: UUID,
        deliver: @escaping @Sendable () async throws -> URL
    ) {
        let timeout = deliveryTimeout
        let task = Task<URL, any Error> {
            // Race delivery against a timeout. We use a continuation
            // guarded by an actor so the first completer wins and the
            // caller resumes immediately. This avoids
            // withThrowingTaskGroup, which waits for ALL children —
            // if deliver() ignores cancellation the group would block
            // after the timeout fires.
            try await withCheckedThrowingContinuation { continuation in
                let race = DeliveryRace(continuation: continuation)

                let timeoutChild = Task {
                    try? await Task.sleep(for: timeout)
                    // Sleep cancelled = delivery won; don't race it
                    // to the actor with a spurious timeout error.
                    guard !Task.isCancelled else { return }
                    await race.complete(
                        with: .failure(ImportFailure.deliveryTimedOut)
                    )
                }

                Task {
                    do {
                        let url = try await deliver()
                        timeoutChild.cancel()
                        await race.complete(with: .success(url))
                    } catch {
                        timeoutChild.cancel()
                        await race.complete(with: .failure(error))
                    }
                }
            }
        }
        deliveryTasks[itemID] = task

        Task { @MainActor [weak self] in
            do {
                let url = try await task.value
                guard let self, let idx = itemIndex(id: itemID) else { return }
                // Late callback: ignore if the item already left .receiving
                // (e.g. timed out while worker was waiting).
                guard items[idx].status == .receiving else { return }
                items[idx].sourceURL = url
                items[idx].displayName = url.lastPathComponent
                items[idx].status = .waiting
                startDateRead(itemID: itemID, url: url)
            } catch {
                guard let self, let idx = itemIndex(id: itemID) else { return }
                // Late callback: ignore if the item already left .receiving.
                guard items[idx].status == .receiving else { return }
                let failure = (error as? ImportFailure) ?? .unreadable
                items[idx].status = .failed(failure)
                logger.error(
                    "Promise delivery failed for \(itemID): \(error)"
                )
                await finish(itemID: itemID)
            }
        }
    }

    // MARK: - Date reading

    private func startDateRead(itemID: UUID, url: URL) {
        let reader = metadata
        dateTasks[itemID] = Task { [reader] in
            await reader.meetingDate(for: url)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let date = await dateTasks[itemID]?.value ?? nil
            guard let idx = itemIndex(id: itemID) else { return }
            items[idx].meetingDate = clampDate(
                date, addedAt: items[idx].addedAt
            )
        }
    }

    private func clampDate(_ date: Date?, addedAt: Date) -> Date {
        guard let date else { return addedAt }
        return min(date, addedAt)
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        guard items.contains(where: {
            $0.status == .waiting || $0.status == .receiving
        }) else { return }

        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while let idx = items.firstIndex(where: {
                $0.status == .waiting || $0.status == .receiving
            }) {
                await process(itemID: items[idx].id)
            }
            worker = nil
            run = nil
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func process(itemID: UUID) async {
        guard let idx = itemIndex(id: itemID) else { return }

        // Wait for promise delivery if needed
        if items[idx].status == .receiving {
            let deliveryResult = await deliveryTasks[itemID]?.result
            // Re-look up after await
            guard let idx = itemIndex(id: itemID) else { return }
            if case .failed = items[idx].status {
                await finish(itemID: itemID)
                return
            }
            // The error handler may not have run yet (MainActor scheduling
            // order is not guaranteed). Check the result directly.
            if let deliveryResult, case let .failure(error) = deliveryResult {
                let failure = (error as? ImportFailure) ?? .unreadable
                await fail(itemID: itemID, failure: failure)
                return
            }
            // Apply the URL ourselves in case the startDelivery handler has
            // not yet run.
            if items[idx].sourceURL == nil,
               let deliveryResult,
               case let .success(url) = deliveryResult
            {
                items[idx].sourceURL = url
                items[idx].displayName = url.lastPathComponent
                if dateTasks[itemID] == nil {
                    startDateRead(itemID: itemID, url: url)
                }
            }
        }

        guard let idx = itemIndex(id: itemID) else { return }
        items[idx].status = .converting

        // Await date if not yet resolved
        let dateResult = await dateTasks[itemID]?.value ?? nil
        guard let idx = itemIndex(id: itemID) else { return }
        let addedAt = items[idx].addedAt
        items[idx].meetingDate = clampDate(dateResult, addedAt: addedAt)

        guard let sourceURL = items[idx].sourceURL else {
            await fail(itemID: itemID, failure: .sourceMissing)
            return
        }

        let staging = recordingsRoot
            .appendingPathComponent(".import-staging")
            .appendingPathComponent("\(itemID).aac")

        // Convert
        let result: ConversionResult
        do {
            result = try await converter.convert(
                source: sourceURL, destination: staging
            )
        } catch let failure as ImportFailure {
            await fail(itemID: itemID, failure: failure)
            return
        } catch {
            await fail(itemID: itemID, failure: .unreadable)
            return
        }

        guard let idx = itemIndex(id: itemID) else { return }
        let meetingDate = items[idx].meetingDate ?? addedAt
        let displayName = items[idx].displayName

        // Move to final location
        let meetingID = UUID()
        let meetingDir = recordingsRoot.appendingPathComponent(
            meetingID.uuidString
        )
        let finalPath = meetingDir.appendingPathComponent("system.aac")

        do {
            try FileManager.default.createDirectory(
                at: meetingDir, withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: staging, to: finalPath)
        } catch {
            try? FileManager.default.removeItem(at: meetingDir)
            await fail(itemID: itemID, failure: .saveFailed)
            return
        }

        // Create the meeting in DataStore
        do {
            try await store.createImportedMeeting(
                id: meetingID,
                title: "Imported from \(displayName)",
                start: meetingDate,
                duration: result.duration,
                audioPath: finalPath.path,
                audioByteSize: result.byteSize
            )
        } catch {
            try? FileManager.default.removeItem(at: meetingDir)
            await fail(itemID: itemID, failure: .saveFailed)
            return
        }

        // Auto-tag imported meetings (best-effort — don't fail the import)
        do {
            _ = try await store.createTagAndApply(
                name: "imported", to: meetingID
            )
        } catch {
            logger.warning(
                "Failed to apply 'imported' tag to \(meetingID): \(error)"
            )
        }

        guard let idx = itemIndex(id: itemID) else { return }
        items[idx].status = .done(meetingID: meetingID)

        // Clean up promised file's temp dir
        if items[idx].isPromised, let source = items[idx].sourceURL {
            try? FileManager.default.removeItem(
                at: source.deletingLastPathComponent()
            )
        }

        await finish(itemID: itemID)
    }

    private func fail(itemID: UUID, failure: ImportFailure) async {
        // Remove staging file
        let staging = recordingsRoot
            .appendingPathComponent(".import-staging")
            .appendingPathComponent("\(itemID).aac")
        try? FileManager.default.removeItem(at: staging)

        guard let idx = itemIndex(id: itemID) else { return }
        items[idx].status = .failed(failure)

        // Clean up promised file's temp dir
        if items[idx].isPromised, let source = items[idx].sourceURL {
            try? FileManager.default.removeItem(
                at: source.deletingLastPathComponent()
            )
        }

        let name = items[idx].displayName
        logger.error(
            "Import failed for \(name, privacy: .private): \(failure)"
        )

        await finish(itemID: itemID)
    }

    private func finish(itemID: UUID) async {
        guard !finishedItems.contains(itemID) else { return }
        finishedItems.insert(itemID)
        guard let idx = itemIndex(id: itemID) else { return }
        let item = items[idx]
        let batchSize = batchSizes[item.batchID] ?? 1
        await onItemFinished?(ImportFinished(
            item: item, batchSize: batchSize
        ))
    }

    // MARK: - Helpers

    private func itemIndex(id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }
}

// MARK: - DeliveryRace

/// Guards a single `CheckedContinuation` so exactly one of two racing
/// tasks (delivery vs. timeout) resumes it. The second caller's
/// `complete` is a safe no-op.
private actor DeliveryRace {
    private var continuation: CheckedContinuation<URL, any Error>?

    init(continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    func complete(with result: Result<URL, any Error>) {
        guard let cont = continuation else {
            // Late delivery after timeout — remove the received file's
            // directory so sensitive audio doesn't linger on disk.
            if case let .success(url) = result {
                logger.info("Cleaning up late-delivered promised file")
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                )
            }
            return
        }
        continuation = nil
        switch result {
        case let .success(url): cont.resume(returning: url)
        case let .failure(error): cont.resume(throwing: error)
        }
    }
}
