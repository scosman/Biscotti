#if canImport(Speech)
    import Foundation
    import os.log
    import Speech

    /// Manages Apple Speech locale reservations (A6).
    ///
    /// Each process keeps at most one reserved locale: before reserving the
    /// target locale, release other `AssetInventory.reservedLocales`.
    /// `maximumReservedLocales` is small (~5) and per app; locale changes
    /// would otherwise leak reservations.
    @available(macOS 26, *)
    enum AppleLocaleReservations {
        private static let log = Logger(
            subsystem: "net.scosman.biscotti",
            category: "AppleSpeech"
        )

        /// Release previously reserved locales, then build a
        /// `SpeechTranscriber` for the target locale.
        ///
        /// - Parameter locale: The locale to prepare.
        /// - Returns: A configured `SpeechTranscriber` ready for asset checks
        ///   or transcription.
        static func prepare(locale: Locale) async throws -> SpeechTranscriber {
            // Release other reserved locales to avoid leaking reservations (A6).
            let reserved = await AssetInventory.reservedLocales
            for reservedLocale in reserved where reservedLocale.identifier != locale.identifier {
                log.debug("Releasing reservation for \(reservedLocale.identifier)")
                await AssetInventory.release(reservedLocale: reservedLocale)
            }

            return SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        }
    }
#endif
