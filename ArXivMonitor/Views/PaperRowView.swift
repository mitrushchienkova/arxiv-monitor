import SwiftUI

struct PaperRowView: View {
    let paper: MatchedPaper
    var savedSearches: [SavedSearch] = []
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if paper.isNew {
                    Circle()
                        .fill(.purple)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.title)
                        .font(.system(size: 12, weight: paper.isNew ? .semibold : .regular))
                        .lineLimit(2)
                        .onTapGesture { onOpen() }

                    HStack(spacing: 4) {
                        Text(paper.primaryCategory)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(paper.authors)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if paper.isRevision {
                            Text("· Revised")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("Published: \(formattedDate(paper.publishedAt))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Updated: \(formattedDate(paper.updatedAt))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if !savedSearches.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(paper.matchedSearchIDs, id: \.self) { searchID in
                                if let search = savedSearches.first(where: { $0.id == searchID }) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(search.color)
                                        .frame(width: 8, height: 8)
                                        .help(search.name)
                                }
                            }
                        }
                    }
                }
                Spacer()
            }

            if paper.isNew {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }
}
