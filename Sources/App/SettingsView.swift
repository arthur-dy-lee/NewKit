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
        .frame(width: 520, height: 380)
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

            List(selection: $selection) {
                ForEach(config.allOrderedTypes) { type in
                    row(for: type).tag(type.id)
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
                Button {
                    if let id = selection,
                       let type = config.customTypes.first(where: { $0.id == id }) {
                        config.removeCustomType(id: type.id)
                    }
                } label: { Image(systemName: "minus") }
                .disabled(!isCustomSelected)

                Button {
                    if let id = selection,
                       let type = config.customTypes.first(where: { $0.id == id }) {
                        sheet = .edit(type)
                    }
                } label: { Image(systemName: "pencil") }
                .disabled(!isCustomSelected)

                Spacer()
            }
            .buttonStyle(.bordered)
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

    private var isCustomSelected: Bool {
        guard let id = selection else { return false }
        return config.customTypes.contains(where: { $0.id == id })
    }

    @ViewBuilder
    private func row(for type: FileType) -> some View {
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
            Spacer()
            Toggle("", isOn: bindingForEnabled(type))
                .labelsHidden()
        }
    }

    private func bindingForEnabled(_ type: FileType) -> Binding<Bool> {
        Binding(
            get: { config.isEnabled(type.id) },
            set: { config.setEnabled($0, for: type.id) }
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

// MARK: - Localization helpers

enum L10n {
    static func string(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    static func tab(_ key: String) -> String { NSLocalizedString("settings.tab.\(key)", comment: "") }
}
