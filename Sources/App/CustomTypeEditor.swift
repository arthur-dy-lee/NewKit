import SwiftUI

/// Form for adding/editing a custom file type.
struct CustomTypeEditor: View {
    enum Mode {
        case create
        case edit(FileType)
    }

    let mode: Mode
    let onSave: (FileType) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var ext: String = ""
    @State private var symbol: String = "doc"
    @State private var template: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titleText).font(.title3.bold())

            Form {
                TextField(L10n.string("custom.name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.string("custom.extension"), text: $ext)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.string("custom.symbol"), text: $symbol)
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("custom.template"))
                    TextEditor(text: $template)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(.separator, lineWidth: 1))
                    Text(L10n.string("custom.template.variables"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button(L10n.string("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .onAppear(perform: loadInitial)
    }

    private var titleText: String {
        switch mode {
        case .create: return L10n.string("custom.title.create")
        case .edit:   return L10n.string("custom.title.edit")
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !ext.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadInitial() {
        if case .edit(let t) = mode {
            name = t.menuTitleLiteral ?? t.menuTitle
            ext = t.ext ?? ""
            symbol = t.symbolName ?? "doc"
            template = t.templateContent ?? ""
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedExt = ext.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let trimmedSymbol = symbol.trimmingCharacters(in: .whitespaces)
        let trimmedTemplate = template.isEmpty ? nil : template

        let id: String
        if case .edit(let t) = mode {
            id = t.id
        } else {
            id = "custom.\(UUID().uuidString)"
        }

        let type = FileType(
            id: id,
            ext: trimmedExt.isEmpty ? nil : trimmedExt,
            symbolName: trimmedSymbol.isEmpty ? nil : trimmedSymbol,
            templateContent: trimmedTemplate,
            isFolder: false,
            isBuiltIn: false,
            menuTitleKey: nil,
            menuTitleLiteral: trimmedName,
            defaultNameKey: nil,
            defaultNameLiteral: L10n.string("custom.defaultname")
        )
        onSave(type)
    }
}
