/// Named constants for every vocabulary threshold. No threshold is inlined
/// anywhere else in the module.
public enum VocabularyLimits {
    /// Maximum number of terms from the user's stored list that contribute
    /// to the effective vocabulary.
    public static let maxUserTerms = 12

    /// Maximum total terms in the effective vocabulary.
    public static let maxEffectiveTerms = 40

    /// Maximum character count when terms are joined with `", "` separators.
    public static let maxJoinedCharacters = 700

    /// Maximum character length for a single user-entered term.
    public static let maxSingleTermLength = 60

    /// If the raw invitee count (organizer + participants, before de-dup)
    /// exceeds this, no attendee names are contributed.
    public static let maxInvitees = 20

    /// If the number of unique non-free-mail domains exceeds this,
    /// no company names are contributed.
    public static let maxUniqueDomains = 5

    /// Minimum character length for a tokenized word to be kept.
    public static let minTokenLength = 3

    /// Minimum character length for an attendee first name to be kept.
    public static let minNameLength = 2

    /// Hit-rate ceiling when there are `shortTextWordCount` or fewer checked words.
    public static let shortTextHitRateCeiling = 0.34

    /// Checked-word count at or below which `shortTextHitRateCeiling` applies.
    public static let shortTextWordCount = 5

    /// Hit-rate ceiling above `shortTextWordCount` checked words.
    public static let longTextHitRateCeiling = 0.25
}
