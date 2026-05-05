import AppKit
import SwiftUI

struct LogsSettingsView: View {
    @State private var lastResult: String?
    @State private var lastError: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string("logs.path.label"))
                    Spacer()
                    Text(Log.logsDirectory.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button(L10n.string("logs.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.logsDirectory])
                    }
                    Button(L10n.string("logs.export")) {
                        do {
                            let url = try LogExporter.exportToDesktop()
                            lastResult = url.lastPathComponent
                            lastError = nil
                        } catch LogExporter.ExportError.noLogs {
                            lastError = L10n.string("logs.error.empty")
                        } catch {
                            lastError = "\(error)"
                        }
                    }
                }
                if let lastResult {
                    Label(lastResult, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if let lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L10n.string("logs.section"))
            } footer: {
                Text(L10n.string("logs.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
