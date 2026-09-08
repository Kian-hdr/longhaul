import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Power capabilities") {
                LabeledContent("Idle-sleep protection", value: model.isHolding ? "Active" : "Available")
                LabeledContent("Closed-lid protection", value: model.lidProtection.active ? "Active" : model.lidProtection.state.rawValue)
                Text(model.lidProtection.detail).font(.callout).foregroundStyle(.secondary)
                Text("Closed-lid work and locked Computer Use are separate capabilities. Longhaul does not bypass the lock screen or disable macOS emergency protections.").font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Export Diagnostic History…") { model.exportHistory() }
                Button("Show Local Data") { model.reveal(model.root.path) }
                Text("History stays on this Mac. Exported events can include job titles; review them before sharing.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
