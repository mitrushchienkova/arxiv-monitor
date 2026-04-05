import SwiftUI

struct AddSearchSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// If non-nil, we're editing an existing search.
    var editingSearch: SavedSearch?

    @State private var name: String = ""
    @State private var clauses: [SearchClause] = [
        SearchClause(field: .keyword, value: "", scope: .titleAndAbstract)
    ]
    @State private var combineOperator: ClauseCombineOperator = .and

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editingSearch != nil ? "Edit Saved Search" : "New Saved Search")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            TextField("Name", text: $name, prompt: Text("e.g. Mirror Symmetry papers"))
                .textFieldStyle(.roundedBorder)

            Text("CLAUSES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Combine clauses with", selection: $combineOperator) {
                Text("AND (all must match)").tag(ClauseCombineOperator.and)
                Text("OR (any can match)").tag(ClauseCombineOperator.or)
            }
            .pickerStyle(.radioGroup)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($clauses) { $clause in
                        clauseRow(clause: $clause)
                    }
                }
            }
            .frame(maxHeight: 300)

            Button(action: addClause) {
                Label("Add Clause", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveSearch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || clauses.allSatisfy { $0.value.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let search = editingSearch {
                name = search.name
                clauses = search.clauses
                combineOperator = search.combineOperator
            }
        }
    }

    @ViewBuilder
    private func clauseRow(clause: Binding<SearchClause>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Field", selection: clause.field) {
                        Text("Keyword").tag(SearchField.keyword)
                        Text("Category").tag(SearchField.category)
                        Text("Author").tag(SearchField.author)
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    TextField(placeholderFor(clause.wrappedValue.field), text: clause.value)
                        .textFieldStyle(.roundedBorder)

                    if clauses.count > 1 {
                        Button("Remove") {
                            clauses.removeAll { $0.id == clause.wrappedValue.id }
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }

                if clause.wrappedValue.field == .keyword {
                    Picker("Scope", selection: Binding(
                        get: { clause.wrappedValue.scope ?? .titleAndAbstract },
                        set: { clause.wrappedValue.scope = $0 }
                    )) {
                        Text("Title + Abstract").tag(MatchScope.titleAndAbstract)
                        Text("Title only").tag(MatchScope.title)
                        Text("Abstract only").tag(MatchScope.abstract)
                    }
                    .pickerStyle(.radioGroup)
                    .font(.system(size: 11))
                }
            }
            .padding(4)
        }
    }

    private func placeholderFor(_ field: SearchField) -> String {
        switch field {
        case .keyword: return "e.g. flow matching"
        case .category: return "e.g. cs.LG"
        case .author: return "e.g. Hinton"
        }
    }

    private func addClause() {
        clauses.append(SearchClause(field: .keyword, value: "", scope: .titleAndAbstract))
    }

    private func saveSearch() {
        let trimmedClauses = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !trimmedClauses.isEmpty else { return }

        if var existing = editingSearch {
            existing.name = name
            existing.clauses = trimmedClauses
            existing.combineOperator = combineOperator
            appState.updateSearch(existing)
        } else {
            let search = SavedSearch(name: name, clauses: trimmedClauses, combineOperator: combineOperator)
            appState.addSearch(search)
        }
        dismiss()
    }
}
