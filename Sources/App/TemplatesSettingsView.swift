import SwiftUI

/// Settings tab where users can override the default template content for any text-based file type.
/// Office types (xlsx/docx/pptx) are skipped — they use binary OOXML blanks.
struct TemplatesSettingsView: View {
    @ObservedObject var config: Configuration
    @State private var selection: String?

    var body: some View {
        HSplitView {
            List(textBasedTypes, id: \.id, selection: $selection) { type in
                HStack {
                    if let symbol = type.symbolName {
                        Image(systemName: symbol).frame(width: 18)
                    }
                    Text(type.menuTitle)
                    if !overrideValue(for: type.id).isEmpty {
                        Spacer()
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.tint)
                            .help(L10n.string("templates.overridden"))
                    }
                }
                .tag(type.id)
            }
            .frame(minWidth: 180)

            VStack(alignment: .leading, spacing: 8) {
                if let id = selection, let type = lookup(id) {
                    Text(type.menuTitle).font(.headline)
                    Text(L10n.string("custom.template.variables"))
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: binding(for: id))
                        .font(.system(.body, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(.separator, lineWidth: 1))
                    HStack {
                        Spacer()
                        Button(L10n.string("templates.reset"), role: .destructive) {
                            config.templateOverrides.removeValue(forKey: id)
                        }
                        .disabled(overrideValue(for: id).isEmpty)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text(L10n.string("templates.empty")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
        }
    }

    private var textBasedTypes: [FileType] {
        config.allOrderedTypes.filter { !$0.isFolder && $0.bundledTemplateName == nil }
    }

    private func lookup(_ id: String) -> FileType? {
        config.allOrderedTypes.first { $0.id == id }
    }

    private func overrideValue(for id: String) -> String {
        config.templateOverrides[id] ?? ""
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: {
                if let v = config.templateOverrides[id] { return v }
                return lookup(id)?.templateContent ?? ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    config.templateOverrides.removeValue(forKey: id)
                } else {
                    config.templateOverrides[id] = newValue
                }
            }
        )
    }
}
