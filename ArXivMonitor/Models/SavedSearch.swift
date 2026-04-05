import Foundation
import SwiftUI

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

/// Default palette for auto-assigning colors to new searches.
let searchColorPalette: [String] = [
    "#5E5CE6", // indigo
    "#30B0C7", // teal
    "#AC4FC6", // purple
    "#FF6482", // pink
    "#FF9F0A", // orange
    "#FFD60A", // yellow
    "#32D74B", // green
    "#0A84FF", // blue
]

struct SavedSearch: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var clauses: [SearchClause]
    var combineOperator: ClauseCombineOperator
    var lastQueriedAt: String?
    var colorHex: String
    var isPaused: Bool
    var fetchFromDate: String?

    init(id: UUID = UUID(), name: String, clauses: [SearchClause],
         combineOperator: ClauseCombineOperator = .and, lastQueriedAt: String? = nil,
         colorHex: String = searchColorPalette[0], isPaused: Bool = false,
         fetchFromDate: String? = nil) {
        self.id = id
        self.name = name
        self.clauses = clauses
        self.combineOperator = combineOperator
        self.lastQueriedAt = lastQueriedAt
        self.colorHex = colorHex
        self.isPaused = isPaused
        self.fetchFromDate = fetchFromDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        clauses = try container.decode([SearchClause].self, forKey: .clauses)
        combineOperator = try container.decodeIfPresent(ClauseCombineOperator.self, forKey: .combineOperator) ?? .and
        lastQueriedAt = try container.decodeIfPresent(String.self, forKey: .lastQueriedAt)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? searchColorPalette[0]
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        fetchFromDate = try container.decodeIfPresent(String.self, forKey: .fetchFromDate)
    }

    /// True when every clause is an author clause (no keywords or categories).
    var isAuthorOnly: Bool {
        !clauses.isEmpty && clauses.allSatisfy { $0.field == .author }
    }

    /// The effective "from" date for the API query.
    /// Applies to ALL search types — the submittedDate filter is type-agnostic.
    /// - If `fetchFromDate` is explicitly set, use that (regardless of search type).
    /// - If nil and the search is author-only, return nil (all time — the default for authors).
    /// - If nil and the search has keywords/categories, return 90 days ago (the default for keywords).
    var effectiveFetchFromDate: Date? {
        if let dateStr = fetchFromDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: dateStr)
        }
        if isAuthorOnly {
            return nil  // default for author-only: all time
        }
        // Default for keyword/category/mixed: 90 days ago
        return Calendar.current.date(byAdding: .day, value: -90, to: Date())
    }

    /// SwiftUI Color from the persisted hex string.
    var color: Color {
        Color(hex: colorHex)
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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}
