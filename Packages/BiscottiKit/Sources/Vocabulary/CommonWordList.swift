import Foundation
import os

/// Loads the bundled common-word list and scans it to identify uncommon words.
///
/// The list is read transiently and released immediately after each call.
/// Nothing is retained between invocations — this is a hard requirement.
public enum CommonWordList {
    /// Returns a closure suitable for `VocabularyAssembler.assemble(_:uncommon:)`.
    ///
    /// On any load failure, returns a closure that yields an empty set — i.e.
    /// "no word is uncommon", so the uncommon-word method contributes nothing.
    public static func uncommonFilter(logger: Logger) -> (Set<String>) -> Set<String> {
        { candidates in
            do {
                return try uncommon(from: candidates)
            } catch {
                logger.error("Failed to load common word list: \(error.localizedDescription)")
                return []
            }
        }
    }

    /// Returns the members of `candidates` absent from the bundled list.
    ///
    /// `candidates` must be lowercased. The algorithm builds a small `Set<Substring>`
    /// from the candidates, then makes one pass over the list, removing matches.
    /// Anything left in the set after the pass is uncommon.
    public static func uncommon(from candidates: Set<String>) throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }

        guard let url = Bundle.module.url(forResource: "common_words_en", withExtension: "txt") else {
            throw CommonWordListError.resourceMissing
        }

        let text = try String(contentsOf: url, encoding: .utf8)

        // Build a mutable set of Substring slices from the candidates.
        // Substring hashes/compares by character content, so slices of
        // different strings match correctly. This avoids allocating a
        // String per line of the word list.
        var remaining = Set(candidates.map { $0[...] })

        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where remaining.contains(line)
        {
            remaining.remove(line)
            if remaining.isEmpty { break }
        }

        return Set(remaining.map(String.init))
    }
}

enum CommonWordListError: Error {
    case resourceMissing
}
