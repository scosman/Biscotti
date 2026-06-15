import ArgumentParser
import Foundation
import LocalLLM
import Synchronization

struct DownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a GGUF model file."
    )

    @Option(name: .long, help: "URL to download from.")
    var url: String = ModelDownloader.defaultModelURL.absoluteString

    @Option(name: .long, help: "Cache directory to store the model in.")
    var dest: String = LocalLLMPaths.defaultModelCacheDir.path

    // swiftlint:disable:next function_body_length
    mutating func run() async throws {
        guard let sourceURL = URL(string: url) else {
            throw ValidationError("Invalid URL: \(url)")
        }
        let cacheDir = URL(fileURLWithPath: (dest as NSString).expandingTildeInPath)

        let downloader = ModelDownloader(cacheDirectory: cacheDir)

        logStderr("Checking for \(sourceURL.lastPathComponent)...")

        do {
            // Progress tracking for stderr. Mutex for Sendable closure safety (Swift 6).
            let lastUpdate = Mutex(ContinuousClock.now)
            let updateInterval = Duration.milliseconds(500)
            let downloadStarted = Mutex(false)

            let finalPath = try await downloader.download(
                from: sourceURL,
                progress: { bytes, total in
                    // On first progress callback, we know a real download is happening
                    let isFirst = downloadStarted.withLock { started in
                        if !started { started = true; return true }
                        return false
                    }
                    if isFirst {
                        logStderr("Downloading...")
                    }

                    let now = ContinuousClock.now
                    let shouldUpdate = lastUpdate.withLock { last in
                        guard now - last >= updateInterval else { return false }
                        last = now
                        return true
                    }
                    guard shouldUpdate else { return }

                    let megabytes = Double(bytes) / 1_000_000
                    if let total {
                        let totalMB = Double(total) / 1_000_000
                        let pct = totalMB > 0 ? (megabytes / totalMB) * 100 : 0
                        FileHandle.standardError.write(
                            Data(String(format: "\r  %.0f / %.0f MB (%.0f%%)", megabytes, totalMB, pct).utf8)
                        )
                    } else {
                        FileHandle.standardError.write(
                            Data(String(format: "\r  %.0f MB downloaded", megabytes).utf8)
                        )
                    }
                }
            )

            let didDownload = downloadStarted.withLock { $0 }
            if didDownload {
                logStderr("")
            } else {
                logStderr("Already downloaded.")
            }

            // Print the final model path to stdout (clean, pipeable)
            print(finalPath.path)
        } catch {
            logStderr("")
            throw error
        }
    }
}
