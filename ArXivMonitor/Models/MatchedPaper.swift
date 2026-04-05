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
    var isTrash: Bool

    /// Whether this paper is a revision (updated after initial publication).
    var isRevision: Bool {
        updatedAt > publishedAt
    }

    init(id: String, title: String, authors: String, primaryCategory: String,
         categories: [String], publishedAt: String, updatedAt: String, link: String,
         matchedSearchIDs: [UUID], foundAt: String, isNew: Bool, isTrash: Bool = false) {
        self.id = id
        self.title = title
        self.authors = authors
        self.primaryCategory = primaryCategory
        self.categories = categories
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.link = link
        self.matchedSearchIDs = matchedSearchIDs
        self.foundAt = foundAt
        self.isNew = isNew
        self.isTrash = isTrash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        authors = try container.decode(String.self, forKey: .authors)
        primaryCategory = try container.decode(String.self, forKey: .primaryCategory)
        categories = try container.decode([String].self, forKey: .categories)
        publishedAt = try container.decode(String.self, forKey: .publishedAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        link = try container.decode(String.self, forKey: .link)
        matchedSearchIDs = try container.decode([UUID].self, forKey: .matchedSearchIDs)
        foundAt = try container.decode(String.self, forKey: .foundAt)
        isNew = try container.decode(Bool.self, forKey: .isNew)
        isTrash = try container.decodeIfPresent(Bool.self, forKey: .isTrash) ?? false
    }
}
