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
    @State private var colorHex: String = searchColorPalette[0]
    @State private var useFetchFromDate: Bool = false
    @State private var fetchFromDate: Date = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
    @State private var showClauseChangeWarning = false

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

            HStack {
                Text("Color")
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { Color(hex: colorHex) },
                    set: { newColor in
                        if let cgColor = NSColor(newColor).usingColorSpace(.sRGB) {
                            let r = Int(cgColor.redComponent * 255)
                            let g = Int(cgColor.greenComponent * 255)
                            let b = Int(cgColor.blueComponent * 255)
                            colorHex = String(format: "#%02X%02X%02X", r, g, b)
                        }
                    }
                ))
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Fetch articles from specific date", isOn: $useFetchFromDate)
                    .font(.system(size: 12))

                if useFetchFromDate {
                    DatePicker(
                        "From:",
                        selection: $fetchFromDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .frame(width: 140)

                    Text("Only articles submitted on or after this date will be fetched.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(isCurrentSearchAuthorOnly
                        ? "Default: all time (author search)"
                        : "Default: last 90 days")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

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
                colorHex = search.colorHex
                if let dateStr = search.fetchFromDate {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    formatter.timeZone = TimeZone(identifier: "UTC")
                    if let date = formatter.date(from: dateStr) {
                        fetchFromDate = date
                        useFetchFromDate = true
                    }
                }
            } else {
                let paletteIndex = appState.savedSearches.count % searchColorPalette.count
                colorHex = searchColorPalette[paletteIndex]
            }
        }
        .alert("Change Search Criteria?", isPresented: $showClauseChangeWarning) {
            Button("Continue", role: .destructive) {
                confirmSave()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Changing search criteria will remove existing results for this search. Continue?")
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

    private var isCurrentSearchAuthorOnly: Bool {
        let nonEmpty = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        return !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.field == .author }
    }

    private func placeholderFor(_ field: SearchField) -> String {
        switch field {
        case .keyword: return "e.g. mirror symmetry, SYZ"
        case .category: return "e.g. math.AG, hep-th, math.SG"
        case .author: return "e.g. Hinton"
        }
    }

    private func addClause() {
        clauses.append(SearchClause(field: .keyword, value: "", scope: .titleAndAbstract))
    }

    private func resolvedFetchFromDate() -> String? {
        guard useFetchFromDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: fetchFromDate)
    }

    private func saveSearch() {
        let trimmedClauses = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !trimmedClauses.isEmpty else { return }

        if let existing = editingSearch {
            var updated = existing
            updated.name = name
            updated.clauses = trimmedClauses
            updated.combineOperator = combineOperator
            updated.colorHex = colorHex
            updated.fetchFromDate = resolvedFetchFromDate()

            if !existing.clausesEqual(to: updated) {
                showClauseChangeWarning = true
            } else {
                appState.updateSearch(updated)
                dismiss()
            }
        } else {
            let search = SavedSearch(name: name, clauses: trimmedClauses,
                                     combineOperator: combineOperator, colorHex: colorHex,
                                     fetchFromDate: resolvedFetchFromDate())
            appState.addSearch(search)
            dismiss()
        }
    }

    private func confirmSave() {
        let trimmedClauses = clauses.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard var existing = editingSearch else { return }
        existing.name = name
        existing.clauses = trimmedClauses
        existing.combineOperator = combineOperator
        existing.colorHex = colorHex
        existing.fetchFromDate = resolvedFetchFromDate()
        appState.updateSearch(existing)
        dismiss()
    }
}
