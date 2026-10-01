/// Assembles the effective vocabulary from all sources.
///
/// Pure function over `VocabularyInputs` — no side effects, no store reads,
/// no bundle access. The `uncommon` closure is injected so tests can supply
/// a fake word list and the caller can degrade gracefully on load failure.
public enum VocabularyAssembler {
    /// Assembles the effective vocabulary for one transcription job.
    ///
    /// - Parameters:
    ///   - inputs: All vocabulary sources as plain values.
    ///   - uncommon: Given a set of lowercased candidate words, returns the
    ///     subset that is NOT in the common-word list.
    /// - Returns: Ordered, de-duplicated, capped term list ready for the engine.
    public static func assemble(
        _ inputs: VocabularyInputs,
        uncommon: (Set<String>) -> Set<String>
    ) -> [String] {
        // Step 1: User terms — verbatim, no casing normalization.
        var terms = inputs.userTerms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if terms.count > VocabularyLimits.maxUserTerms {
            terms = Array(terms.prefix(VocabularyLimits.maxUserTerms))
        }

        // Step 2: Calendar-derived terms.
        if inputs.calendarEnabled {
            let names = NameExtractor.firstNames(
                from: inputs.attendeeNames,
                rawInviteeCount: inputs.rawInviteeCount
            )
            terms.append(contentsOf: names)

            let companies = CompanyExtractor.companyNames(from: inputs.attendeeEmails)
            terms.append(contentsOf: companies)

            let uncommonWords = UncommonWordExtractor.terms(
                title: inputs.eventTitle,
                notes: inputs.eventNotes,
                uncommon: uncommon
            )
            terms.append(contentsOf: uncommonWords)
        }

        // Step 3: De-duplicate case-insensitively, keeping the first occurrence.
        var seenKeys: Set<String> = []
        var deduped: [String] = []
        for term in terms {
            let key = term.lowercased()
            if seenKeys.insert(key).inserted {
                deduped.append(term)
            }
        }

        // Step 4: Cap at maxEffectiveTerms.
        if deduped.count > VocabularyLimits.maxEffectiveTerms {
            deduped = Array(deduped.prefix(VocabularyLimits.maxEffectiveTerms))
        }

        // Step 5: Cap by joined character count.
        // Compute incrementally: total = sum of term lengths + 2 * (count - 1) separators.
        deduped = applyCharacterCap(deduped)

        return deduped
    }

    /// Drops terms from the end until the joined text fits within the character cap.
    private static func applyCharacterCap(_ terms: [String]) -> [String] {
        guard !terms.isEmpty else { return [] }

        // Running total of characters: sum of term lengths + separator overhead.
        var totalChars = 0
        var separatorChars = 0
        var result: [String] = []

        for term in terms {
            let newTotal = totalChars + separatorChars + term.count
            if newTotal > VocabularyLimits.maxJoinedCharacters {
                break
            }
            result.append(term)
            totalChars = newTotal
            // Next term adds a ", " separator (2 chars).
            separatorChars = 2
        }

        return result
    }
}
