import Foundation

/// Parses arXiv Atom 1.0 XML responses into MatchedPaper structs.
final class XMLAtomParser: NSObject, XMLParserDelegate {
    private var papers: [MatchedPaper] = []
    private var currentElement = ""
    private var currentText = ""
    private var parseError: Error?

    // Per-entry state
    private var entryID: String?
    private var entryTitle: String?
    private var entryAuthors: [String] = []
    private var entryPublished: String?
    private var entryUpdated: String?
    private var entryPrimaryCategory: String?
    private var entryCategories: [String] = []
    private var entryLink: String?
    private var insideEntry = false
    private var insideAuthor = false

    static func parse(data: Data) throws -> [MatchedPaper] {
        let parser = XMLParser(data: data)
        let delegate = XMLAtomParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        let success = parser.parse()
        if !success, let error = delegate.parseError {
            print("[ArXivMonitor] XML parse error: \(error)")
            throw ArXivError.parseError
        }
        return delegate.papers
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" {
            insideEntry = true
            entryID = nil
            entryTitle = nil
            entryAuthors = []
            entryPublished = nil
            entryUpdated = nil
            entryPrimaryCategory = nil
            entryCategories = []
            entryLink = nil
        } else if elementName == "author" && insideEntry {
            insideAuthor = true
        } else if elementName == "primary_category" && insideEntry {
            if let term = attributes["term"] {
                entryPrimaryCategory = term
            }
        } else if elementName == "category" && insideEntry {
            if let term = attributes["term"] {
                entryCategories.append(term)
            }
        } else if elementName == "link" && insideEntry {
            // Take the first link with rel="alternate" or no rel attribute
            let rel = attributes["rel"] ?? "alternate"
            if rel == "alternate", entryLink == nil {
                entryLink = attributes["href"]
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "entry" {
            if let rawID = entryID,
               let title = entryTitle,
               let published = entryPublished,
               let updated = entryUpdated {

                // Skip arXiv API error entries
                if rawID.contains("arxiv.org/api/errors") {
                    insideEntry = false
                    return
                }

                // Extract arXiv ID from URL: http://arxiv.org/abs/2404.12345v1 -> 2404.12345
                let arxivID = extractArXivID(from: rawID)
                let link = "https://arxiv.org/abs/\(arxivID)"
                let authorsString = entryAuthors.joined(separator: ", ")

                let paper = MatchedPaper(
                    id: arxivID,
                    title: title,
                    authors: authorsString,
                    primaryCategory: entryPrimaryCategory ?? entryCategories.first ?? "unknown",
                    categories: entryCategories,
                    publishedAt: published,
                    updatedAt: updated,
                    link: link,
                    matchedSearchIDs: [],
                    foundAt: ISO8601DateFormatter().string(from: Date()),
                    isNew: false
                )
                papers.append(paper)
            }
            insideEntry = false
        } else if elementName == "author" {
            insideAuthor = false
        } else if elementName == "name" && insideAuthor && insideEntry {
            if !text.isEmpty {
                entryAuthors.append(text)
            }
        } else if elementName == "id" && insideEntry {
            entryID = text
        } else if elementName == "title" && insideEntry {
            // Collapse whitespace in title (arXiv titles often have line breaks)
            entryTitle = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else if elementName == "published" && insideEntry {
            entryPublished = text
        } else if elementName == "updated" && insideEntry {
            entryUpdated = text
        }
    }

    /// Extract arXiv ID from the full URL, stripping version suffix.
    /// e.g. "http://arxiv.org/abs/2404.12345v1" -> "2404.12345"
    private func extractArXivID(from urlString: String) -> String {
        let lastComponent = urlString.components(separatedBy: "/").last ?? urlString
        // Strip version suffix (v1, v2, etc.)
        if let range = lastComponent.range(of: #"v\d+$"#, options: .regularExpression) {
            return String(lastComponent[lastComponent.startIndex..<range.lowerBound])
        }
        return lastComponent
    }
}
