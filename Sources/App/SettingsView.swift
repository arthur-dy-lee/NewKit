import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var config: Configuration

    var body: some View {
        TabView {
            GeneralSettingsView(config: config)
                .tabItem { Label(L10n.tab("general"), systemImage: "gear") }
            FileTypesSettingsView(config: config)
                .tabItem { Label(L10n.tab("filetypes"), systemImage: "doc.on.doc") }
            TemplatesSettingsView(config: config)
                .tabItem { Label(L10n.tab("templates"), systemImage: "doc.plaintext") }
            ShortcutsSettingsView()
                .tabItem { Label(L10n.tab("shortcuts"), systemImage: "command") }
            PermissionsSettingsView()
                .tabItem { Label(L10n.tab("permissions"), systemImage: "lock.shield") }
            LogsSettingsView()
                .tabItem { Label(L10n.tab("logs"), systemImage: "doc.text.magnifyingglass") }
            AboutSettingsView()
                .tabItem { Label(L10n.tab("about"), systemImage: "info.circle") }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 460)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.string("shortcuts.toggle.label"))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleFloatingPanel)
                }
            } footer: {
                Text(L10n.string("shortcuts.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var config: Configuration

    var body: some View {
        Form {
            Section {
                Picker(L10n.string("settings.language.label"),
                       selection: $config.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            } header: {
                Text(L10n.string("settings.language.section"))
            } footer: {
                Text(L10n.string("settings.language.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker(L10n.string("settings.postcreate.label"),
                       selection: $config.postCreateBehavior) {
                    ForEach(PostCreateBehavior.allCases) { behavior in
                        Text(behavior.localizedName).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text(L10n.string("settings.postcreate.section"))
            } footer: {
                Text(L10n.string("settings.postcreate.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                TextField(L10n.string("settings.author.label"), text: $config.author)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text(L10n.string("settings.author.section"))
            } footer: {
                Text(L10n.string("settings.author.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.string("settings.menubar.label"), isOn: $config.showMenuBarIcon)
            } header: {
                Text(L10n.string("settings.menubar.section"))
            } footer: {
                Text(L10n.string("settings.menubar.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.string("settings.rightclick.showseparators.label"),
                       isOn: $config.showSeparatorsInRightClickMenu)
            } header: {
                Text(L10n.string("settings.rightclick.section"))
            } footer: {
                Text(L10n.string("settings.rightclick.showseparators.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - File Types

struct FileTypesSettingsView: View {
    @ObservedObject var config: Configuration
    @State private var sheet: ActiveSheet?
    @State private var selection: String?

    enum ActiveSheet: Identifiable {
        case create
        case edit(FileType)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let t): return "edit-\(t.id)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("settings.filetypes.hint"))
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach(config.allOrderedEntries) { entry in
                    row(for: entry)
                        .listRowBackground(
                            selection == entry.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                        // `.itemProvider` is what actually enables drag in macOS Lists —
                        // `.onMove` alone is silently ignored without it.
                        .itemProvider {
                            NSItemProvider(object: entry.id as NSString)
                        }
                }
                .onMove { source, destination in
                    config.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button {
                    sheet = .create
                } label: { Image(systemName: "plus") }
                .help(L10n.string("settings.filetypes.add.help"))

                Button {
                    deleteSelected()
                } label: { Image(systemName: "minus") }
                .disabled(!isDeletableSelected)
                .help(L10n.string("settings.filetypes.remove.help"))

                Button {
                    if let id = selection,
                       let type = config.customTypes.first(where: { $0.id == id }) {
                        sheet = .edit(type)
                    }
                } label: { Image(systemName: "pencil") }
                .disabled(!isCustomSelected)
                .help(L10n.string("settings.filetypes.edit.help"))

                Divider().frame(height: 18)

                Button {
                    let id = config.addSeparator(beforeID: selection)
                    selection = id
                } label: {
                    Label(L10n.string("settings.filetypes.addseparator"),
                          systemImage: "minus.forwardslash.plus")
                }
                .help(L10n.string("settings.filetypes.addseparator.help"))

                Divider().frame(height: 18)

                Button {
                    if let id = selection { config.moveEntry(id: id, direction: -1) }
                } label: { Image(systemName: "arrow.up") }
                .disabled(!canMoveUp)
                .help(L10n.string("settings.filetypes.moveup.help"))

                Button {
                    if let id = selection { config.moveEntry(id: id, direction: +1) }
                } label: { Image(systemName: "arrow.down") }
                .disabled(!canMoveDown)
                .help(L10n.string("settings.filetypes.movedown.help"))

                Spacer()
            }
            .buttonStyle(.bordered)

            Divider()

            Toggle(L10n.string("settings.filetypes.showterminal.label"),
                   isOn: $config.showOpenTerminal)
            Text(L10n.string("settings.filetypes.showterminal.footer"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .sheet(item: $sheet) { active in
            switch active {
            case .create:
                CustomTypeEditor(mode: .create) { newType in
                    config.addCustomType(newType)
                    sheet = nil
                } onCancel: { sheet = nil }
            case .edit(let type):
                CustomTypeEditor(mode: .edit(type)) { updated in
                    config.updateCustomType(updated)
                    sheet = nil
                } onCancel: { sheet = nil }
            }
        }
    }

    private var canMoveUp: Bool {
        guard let id = selection,
              let idx = config.orderedIDs.firstIndex(of: id) else { return false }
        return idx > 0
    }

    private var canMoveDown: Bool {
        guard let id = selection,
              let idx = config.orderedIDs.firstIndex(of: id) else { return false }
        return idx < config.orderedIDs.count - 1
    }

    private var isCustomSelected: Bool {
        guard let id = selection else { return false }
        return config.customTypes.contains(where: { $0.id == id })
    }

    private var isSeparatorSelected: Bool {
        guard let id = selection else { return false }
        return Configuration.isSeparatorID(id)
    }

    private var isDeletableSelected: Bool {
        isCustomSelected || isSeparatorSelected
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        if Configuration.isSeparatorID(id) {
            config.removeSeparator(id: id)
            selection = nil
        } else if config.customTypes.contains(where: { $0.id == id }) {
            config.removeCustomType(id: id)
            selection = nil
        }
    }

    @ViewBuilder
    private func row(for entry: MenuEntry) -> some View {
        switch entry {
        case .fileType(let type):
            fileTypeRow(type)
        case .separator(let id, let label):
            separatorRow(id: id, label: label)
        }
    }

    @ViewBuilder
    private func fileTypeRow(_ type: FileType) -> some View {
        HStack(spacing: 10) {
            // Leading "select zone": clicking here selects the row, while leaving the
            // TextField + Toggle on the right untouched so they stay editable on first click.
            HStack(spacing: 10) {
                if let symbol = type.symbolName {
                    Image(systemName: symbol).frame(width: 20)
                } else {
                    Image(systemName: "doc").frame(width: 20).opacity(0)
                }
                Text(type.menuTitle)
                if !type.isBuiltIn {
                    Text(L10n.string("settings.filetypes.custombadge"))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture { selection = type.id }

            TextField(
                type.defaultName,
                text: bindingForDefaultName(type)
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .help(L10n.string("settings.filetypes.defaultname.help"))

            Toggle("", isOn: bindingForEnabled(type))
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func separatorRow(id: String, label _: String?) -> some View {
        // A separator is rendered as a single thin horizontal line. No inline label.
        Rectangle()
            .fill(Color.secondary.opacity(0.5))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .onTapGesture { selection = id }
    }

    private func bindingForEnabled(_ type: FileType) -> Binding<Bool> {
        Binding(
            get: { config.isEnabled(type.id) },
            set: { config.setEnabled($0, for: type.id) }
        )
    }

    private func bindingForDefaultName(_ type: FileType) -> Binding<String> {
        Binding(
            get: { config.defaultNameOverrides[type.id] ?? "" },
            set: { config.setDefaultNameOverride($0, for: type.id) }
        )
    }

    private func bindingForSeparatorLabel(_ id: String) -> Binding<String> {
        Binding(
            get: { config.separatorLabels[id] ?? "" },
            set: { config.setSeparatorLabel($0, for: id) }
        )
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @State private var trusted: Bool = AccessibilityHelper.isTrusted
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted
                         ? L10n.string("perm.acc.granted")
                         : L10n.string("perm.acc.missing"))
                }
                HStack {
                    Button(L10n.string("perm.acc.request")) {
                        _ = AccessibilityHelper.requestTrustWithPrompt()
                    }
                    Button(L10n.string("perm.acc.opensettings")) {
                        AccessibilityHelper.openSystemSettings()
                    }
                }
            } header: {
                Text(L10n.string("perm.acc.section"))
            } footer: {
                Text(L10n.string("perm.acc.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(timer) { _ in
            let now = AccessibilityHelper.isTrusted
            if now != trusted {
                trusted = now
                if now { RightClickMonitor.shared.start() }
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .frame(width: 96, height: 96)
            }
            Text("NewKit").font(.title.bold())
            Text(versionString).foregroundStyle(.secondary)
            Text(L10n.string("about.tagline"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button(L10n.string("about.openonboarding")) {
                OnboardingWindowController.shared.showAlways()
            }
            Spacer()
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(v) (\(b))"
    }
}
