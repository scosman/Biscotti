/// Extracts company names from attendee email domains.
///
/// Free-mail domains (gmail.com, etc.) are stripped first. If more than 5
/// unique non-free-mail domains remain, no company names are contributed —
/// too many companies means the signal is diluted. The registrable label
/// is extracted using the known multi-part public suffixes, formatted as
/// capitalized words with hyphens replaced by spaces.
enum CompanyExtractor {
    /// Returns company names derived from attendee email addresses.
    ///
    /// - Parameter emails: Raw email addresses from the organizer and participants.
    static func companyNames(from emails: [String]) -> [String] {
        // Extract domains, lowercase, and strip free-mail providers.
        var domains: [String] = []
        for email in emails {
            guard let atIndex = email.lastIndex(of: "@") else { continue }
            let domain = String(email[email.index(after: atIndex)...]).lowercased()
            guard !domain.isEmpty, !FreeMailDomains.all.contains(domain) else { continue }
            domains.append(domain)
        }

        // Deduplicate, preserving first-seen order.
        var uniqueDomains: [String] = []
        var seen: Set<String> = []
        for domain in domains where seen.insert(domain).inserted {
            uniqueDomains.append(domain)
        }

        guard uniqueDomains.count <= VocabularyLimits.maxUniqueDomains else { return [] }

        var result: [String] = []
        for domain in uniqueDomains {
            guard let label = registrableLabel(from: domain) else { continue }
            guard label.count > 2, label != "www" else { continue }

            let formatted = label
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
            result.append(formatted)
        }

        return result
    }

    /// Extracts the registrable label from a domain.
    ///
    /// The registrable label is the label immediately before the public suffix.
    /// For `mail.acme.co.uk` (suffix `co.uk`) → `acme`.
    /// For `acme-corp.com` (no multi-part suffix) → `acme-corp`.
    private static func registrableLabel(from domain: String) -> String? {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard labels.count >= 2 else { return nil }

        // Try to match the longest multi-part suffix from the right.
        for suffixPartCount in stride(from: min(labels.count - 1, 3), through: 2, by: -1) {
            let suffixCandidate = labels.suffix(suffixPartCount).joined(separator: ".")
            if PublicSuffixes.multiPart.contains(suffixCandidate) {
                let labelIndex = labels.count - suffixPartCount - 1
                guard labelIndex >= 0 else { return nil }
                return labels[labelIndex]
            }
        }

        // No multi-part suffix matched — the registrable label is the second-to-last.
        return labels[labels.count - 2]
    }
}
