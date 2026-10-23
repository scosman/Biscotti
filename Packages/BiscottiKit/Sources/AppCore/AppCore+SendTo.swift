import DataStore
import Foundation
import ImportExport
import os

// MARK: - SendOutcome

/// The result of a send-to operation.
public enum SendOutcome: Equatable, Sendable {
    /// The note was sent to the destination app.
    case sent
    /// The note was too large for a URL; the markdown was copied to the clipboard.
    case copiedToClipboard
    /// The send failed (app not installed, URL open failed, or file write error).
    case failed
}

// MARK: - AppCore send-to API

public extension AppCore {
    /// Returns the installed destinations in `CaseIterable` order.
    ///
    /// NSWorkspace URL lookups are sub-millisecond on macOS 15+, so the
    /// check runs live on each call with no cache. Measured at ~0.1 ms
    /// total for all three lookups in a debug build.
    func installedSendDestinations() -> [ExportDestination] {
        ExportDestination.allCases.filter { destination in
            appURL(for: destination) != nil
        }
    }

    /// Sends the meeting content to a destination and records the export.
    ///
    /// Returns `.sent` on success, `.copiedToClipboard` for the oversize
    /// fallback, or `.failed` when the app is not installed or the open fails.
    func send(
        _ source: ExportSource,
        to destination: ExportDestination
    ) async -> SendOutcome {
        let logger = Logger(
            subsystem: "net.scosman.biscotti", category: "SendTo"
        )

        guard let resolvedApp = appURL(for: destination) else {
            logger.warning("send: \(destination.rawValue) app not found")
            return .failed
        }

        let zone = sendEnvironment.timeZone()
        let payload = SendPayload.build(source, for: destination, timeZone: zone)
        let plan = SendPlan.make(payload, source: source, timeZone: zone)

        let planResult = await executePlan(
            plan, destination: destination, appURL: resolvedApp,
            payload: payload, logger: logger
        )
        if let earlyReturn = planResult { return earlyReturn }

        await recordExport(
            destination: destination, payload: payload,
            meetingID: source.meetingID, logger: logger
        )
        logger.info(
            "send: \(destination.rawValue) success (\(payload.markdown.utf8.count) bytes)"
        )
        return .sent
    }

    /// Makes the destination app active without sending anything.
    func openDestinationApp(_ destination: ExportDestination) {
        guard let appURL = appURL(for: destination) else { return }
        sendEnvironment.openApp(appURL)
    }

    // MARK: - Internal helpers

    /// Executes the send plan. Returns a `SendOutcome` for early exits
    /// (failure or clipboard fallback), or nil when the plan succeeded
    /// and the caller should proceed to record the export.
    private func executePlan(
        _ plan: SendPlan,
        destination: ExportDestination,
        appURL: URL,
        payload: SendPayload,
        logger: Logger
    ) async -> SendOutcome? {
        switch plan {
        case let .openURL(url):
            let opened = sendEnvironment.openURL(url)
            guard opened else {
                logger.warning(
                    "send: \(destination.rawValue) openURL returned false"
                )
                return .failed
            }
            return nil

        case let .tooLarge(markdown):
            sendEnvironment.writePasteboard(markdown)
            logger.info(
                "send: \(destination.rawValue) too large (\(payload.markdown.utf8.count) bytes), copied to clipboard"
            )
            return .copiedToClipboard

        case let .handOffFile(fileName, contents):
            do {
                let exportDir = sendEnvironment.tempRoot()
                    .appendingPathComponent("biscotti-export")
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(
                    at: exportDir, withIntermediateDirectories: true
                )
                let fileURL = exportDir.appendingPathComponent(fileName)
                try contents.write(
                    to: fileURL, atomically: true, encoding: .utf8
                )
                try await sendEnvironment.openFile(fileURL, appURL)
            } catch {
                logger.warning(
                    "send: \(destination.rawValue) file hand-off failed: \(error.localizedDescription)"
                )
                return .failed
            }
            return nil
        }
    }

    /// Records the sent export. A store error is logged but does not
    /// change the outcome -- the note was already sent.
    private func recordExport(
        destination: ExportDestination,
        payload: SendPayload,
        meetingID: UUID,
        logger: Logger
    ) async {
        let export = SentExport(
            destination: destination,
            contentHash: payload.contentHash,
            sentAt: sendEnvironment.now()
        )
        do {
            try await store.recordSentExport(export, meetingID: meetingID)
        } catch {
            logger.warning(
                "send: \(destination.rawValue) record failed: \(error.localizedDescription)"
            )
        }
    }

    /// Resolves the app URL for a destination using the environment's lookups.
    private func appURL(for destination: ExportDestination) -> URL? {
        switch destination.detection {
        case let .urlScheme(scheme):
            sendEnvironment.appURLForScheme(scheme)
        case let .bundleID(id):
            sendEnvironment.appURLForBundleID(id)
        }
    }
}
