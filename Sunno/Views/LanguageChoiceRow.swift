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
    @FocusState private var searching: Bool

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
        codes.filter { code in
            let text = "\(code) \(name(code)) \(name(code, in: Locale(identifier: code)))"
            return query.isEmpty || text.localizedStandardContains(query)
        }.sorted { left, right in
            if ["auto", "off"].contains(left) { return !["auto", "off"].contains(right) }
            if ["auto", "off"].contains(right) { return false }
            return name(left).localizedStandardCompare(name(right)) == .orderedAscending
        }
    }

    private func select(_ code: String) {
        isOpen = false
        choose(code)
    }

    var body: some View {
        Button {
            query = ""
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 2)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                if codes.count > 1 {
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(codes.count <= 1)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .help(title == "Translate to" && selected == "off"
              ? "Translate completed captions locally. The first language downloads a 638 MB model." : value)
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search languages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searching)
                    .onSubmit { if let code = matches.first { select(code) } }
                if matches.isEmpty {
                    Text("No matching languages").foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(matches, id: \.self) { code in
                                Button {
                                    select(code)
                                } label: {
                                    HStack {
                                        Text(name(code))
                                        Spacer()
                                        if selected == code { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                    }
                                    .padding(.horizontal, 6).frame(height: 25).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected == code ? .isSelected : [])
                            }
                        }
                    }
                    .frame(height: min(250, CGFloat(matches.count * 26)))
                }
                if title == "Translate to", selected == "off" {
                    Text("First use downloads a 638 MB translation model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10).frame(width: 248)
            .onAppear { searching = true }
        }
    }
}

