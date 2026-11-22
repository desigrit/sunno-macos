import SwiftUI

struct LanguageChoiceRow: View {
    let title: String
    let codes: [String]
    let selected: String
    var detected: String? = nil
    var preparing = false
    let choose: (String) -> Void

    @ViewState private var isOpen = false
    @ViewState private var query = ""
    @ViewState private var candidate: String?

    private func name(_ code: String, in locale: Locale = .current) -> String {
        if code == "off" { return "Off" }
        if code == "auto" { return "Auto" }
        let identifier = code == "jw" ? "jv" : code
        return locale.localizedString(forIdentifier: identifier) ?? code
    }

    private var value: String {
        if selected == "auto", let detected { return "Auto (\(name(detected)))" }
        return name(selected) + (preparing ? "…" : "")
    }

    private var matches: [String] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func rank(_ code: String) -> Int {
            guard !search.isEmpty else { return ["auto", "off"].contains(code) ? 0 : 1 }
            var best = 3
            for value in [code, name(code), name(code, in: Locale(identifier: code))] {
                if value.compare(search, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
                if let range = value.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) {
                    best = min(best, range.lowerBound == value.startIndex ? 1 : 2)
                }
            }
            return best
        }
        return codes.map { ($0, rank($0)) }.filter { $0.1 < 3 }.sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            return name(left.0).localizedStandardCompare(name(right.0)) == .orderedAscending
        }.map { $0.0 }
    }

    private var currentCandidate: String? {
        candidate ?? (query.isEmpty ? selected : nil)
    }

    private func move(_ offset: Int) {
        let list = matches
        guard !list.isEmpty else { return }
        let index = currentCandidate.flatMap { list.firstIndex(of: $0) } ?? 0
        let next = list[max(0, min(list.count - 1, index + offset))]
        guard candidate != next else { return }
        candidate = next
        if let window = NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: name(next), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func select(_ code: String) {
        isOpen = false
        choose(code)
    }

    var body: some View {
        Button {
            query = ""
            candidate = selected
            isOpen = true
        } label: {
            HStack(spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(title).fixedSize()
                        Spacer(minLength: 0)
                        Text(value).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        Text(value).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if codes.count > 1 {
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(codes.count <= 1)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .help(title == "Translate to" && selected == "off"
              ? "Translate completed captions locally. The first language downloads a 638 MB model." : value)
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            let filtered = matches
            VStack(alignment: .leading, spacing: 8) {
                LanguageSearchField(query: $query, move: move) {
                    if let code = currentCandidate { select(code) }
                }
                .frame(height: 24)
                .onChange(of: query) { _ in candidate = query.isEmpty ? selected : matches.first }
                if filtered.isEmpty {
                    Text("No matching languages").foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(filtered, id: \.self) { code in
                                    Button {
                                        select(code)
                                    } label: {
                                        HStack {
                                            Text(name(code))
                                            Spacer()
                                            if selected == code { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                        }
                                        .padding(.horizontal, 6).frame(height: 25)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(
                                            currentCandidate == code ? Color.primary.opacity(0.09) : Color.clear))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(code)
                                    .accessibilityAddTraits(selected == code ? .isSelected : [])
                                }
                            }
                        }
                        .onAppear { if let code = currentCandidate { reader.scrollTo(code) } }
                        .onChange(of: currentCandidate) { code in
                            if let code { reader.scrollTo(code) }
                        }
                    }
                    .frame(height: min(250, CGFloat(filtered.count * 26)))
                }
                if title == "Translate to", selected == "off" {
                    Text("First use downloads a 638 MB translation model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10).frame(width: 248)
        }
    }
}

/// Route the search field's standard AppKit editing commands on macOS 13 and later.
private struct LanguageSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search languages"
        field.setAccessibilityLabel("Search languages")
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.owner = self
        if field.stringValue != query { field.stringValue = query }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var owner: LanguageSearchField
        init(_ owner: LanguageSearchField) { self.owner = owner }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { owner.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)): owner.move(1)
            case #selector(NSResponder.moveUp(_:)): owner.move(-1)
            case #selector(NSResponder.insertNewline(_:)): owner.submit()
            default: return false
            }
            return true
        }
    }
}
