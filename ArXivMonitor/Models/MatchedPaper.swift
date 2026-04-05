import Foundation

struct MatchedPaper: Codable, Identifiable {
    let id: String              // arXiv ID, e.g. "2404.12345"
    var title: String
    var authors: String         // "Smith, Chen, Wang"
    var primaryCategory: String // "cs.LG"
    var categories: [String]    // ["cs.LG", "cs.AI", "stat.ML"]
    var publishedAt: String     // ISO8601
    var updatedAt: String       // ISO8601
    var link: String            // URL to arXiv page
    var matchedSearchIDs: [UUID]
    let foundAt: String         // ISO8601 when first added — immutable
    var isNew: Bool

    /// Whether this paper is a revision (updated after initial publication).
    var isRevision: Bool {
        updatedAt > publishedAt
    }
}
