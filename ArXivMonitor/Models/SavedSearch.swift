import Foundation

enum SearchField: String, Codable, CaseIterable {
    case keyword, category, author
}

enum MatchScope: String, Codable, CaseIterable {
    case title, abstract, titleAndAbstract
}

struct SearchClause: Codable, Identifiable, Equatable {
    let id: UUID
    var field: SearchField
    var value: String
    var scope: MatchScope?

    init(id: UUID = UUID(), field: SearchField, value: String, scope: MatchScope? = nil) {
        self.id = id
        self.field = field
        self.value = value
        self.scope = scope
    }

    static func == (lhs: SearchClause, rhs: SearchClause) -> Bool {
        lhs.field == rhs.field && lhs.value == rhs.value && lhs.scope == rhs.scope
    }
}

enum ClauseCombineOperator: String, Codable, CaseIterable {
    case and, or
}

struct SavedSearch: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var clauses: [SearchClause]
    var combineOperator: ClauseCombineOperator
    var lastQueriedAt: String?

    init(id: UUID = UUID(), name: String, clauses: [SearchClause],
         combineOperator: ClauseCombineOperator = .and, lastQueriedAt: String? = nil) {
        self.id = id
        self.name = name
        self.clauses = clauses
        self.combineOperator = combineOperator
        self.lastQueriedAt = lastQueriedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        clauses = try container.decode([SearchClause].self, forKey: .clauses)
        combineOperator = try container.decodeIfPresent(ClauseCombineOperator.self, forKey: .combineOperator) ?? .and
        lastQueriedAt = try container.decodeIfPresent(String.self, forKey: .lastQueriedAt)
    }

    static func == (lhs: SavedSearch, rhs: SavedSearch) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Compare clauses ignoring order (since they are ANDed).
    /// Sorts by (field, value, scope) to be stable regardless of UUID changes.
    func clausesEqual(to other: SavedSearch) -> Bool {
        guard combineOperator == other.combineOperator else { return false }
        guard clauses.count == other.clauses.count else { return false }
        let lhs = clauses.sorted { a, b in
            if a.field.rawValue != b.field.rawValue { return a.field.rawValue < b.field.rawValue }
            if a.value != b.value { return a.value < b.value }
            return (a.scope?.rawValue ?? "") < (b.scope?.rawValue ?? "")
        }
        let rhs = other.clauses.sorted { a, b in
            if a.field.rawValue != b.field.rawValue { return a.field.rawValue < b.field.rawValue }
            if a.value != b.value { return a.value < b.value }
            return (a.scope?.rawValue ?? "") < (b.scope?.rawValue ?? "")
        }
        return lhs == rhs
    }
}
