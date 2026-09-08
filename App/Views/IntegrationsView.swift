import SwiftUI
import ServiceManagement

struct IntegrationsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Codex") {
                Toggle("Read native Codex activity", isOn: Binding(get: { model.codexActivityEnabled }, set: { model.codexActivityEnabled = $0; model.saveCodexActivitySetting() }))
                    .disabled(!model.canConfigure)
                Text(model.codexActivityStatus).font(.callout)
                Text("Reads lifecycle metadata from session files currently open in Codex. Conversation text is not retained. This also covers tasks started before hook setup on supported Codex versions.").font(.callout).foregroundStyle(.secondary)
                Text("Lifecycle hooks · setup and trust required").font(.headline)
                Text("Hooks report job events without copying your conversation. Enable the generated hook configuration in each Codex profile and review it through Codex's hook-trust flow.").font(.callout).foregroundStyle(.secondary)
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(profile.name).font(.headline)
                            Spacer()
                            Button("Set Up Hooks") { model.installHooks(profile) }.disabled(model.setupInProgress || !model.canConfigure)
                            if (model.profileStatus[profile.id]?.managedCount ?? 0) > 0 {
                                Button("Remove Hooks") { model.removeHooks(profile) }.disabled(model.setupInProgress || !model.canConfigure)
                            }
                        }
                        Text(model.profileStatus[profile.id]?.detail ?? "Status unavailable").font(.callout).foregroundStyle(.secondary)
                        Text(model.codexReportingDescription(profile)).font(.callout)
                    }
                }
                if let message = model.integrationMessage { Text(message).font(.callout).textSelection(.enabled) }
                Button("Check Again") { Task { await model.refreshIntegrationStatus() } }
                    .disabled(model.setupInProgress)
                Button("Show Integration Instructions") { if let url = Bundle.main.url(forResource: "INTEGRATIONS", withExtension: "md") { NSWorkspace.shared.open(url) } }
            }
            Section("Blender") {
                Text("Render lifecycle add-on · " + (model.blenderStatus?.state.rawValue ?? "Status unavailable"))
                Text("Reports render start, completion and cancellation. Saves recovery copies only when supported and enabled.").font(.callout).foregroundStyle(.secondary)
                Button("Install Blender Integration") { model.installBlender() }.disabled(model.setupInProgress || !model.canConfigure)
            }
            Section("DaVinci Resolve") {
                Toggle("Monitor Resolve exports", isOn: Binding(get: { model.resolve.enabled }, set: { model.setResolve($0) })).disabled(!model.canConfigure)
                Text(model.resolve.status)
                Text("Resolve edition and scripting access determine availability. Deliver jobs and Quick Export require separate checks.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Nodebay") {
                LabeledContent("Optional companion", value: model.companion.status)
                Text("Nodebay can show job progress and important notices in the notch. Longhaul keeps control of power and recovery.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(model.nodebayPaired ? "Reconnect Nodebay" : "Connect Nodebay") { model.connectNodebay() }.disabled(!model.canConfigure)
                    if model.nodebayPaired { Button("Disconnect") { model.disconnectNodebay() }.disabled(!model.canConfigure) }
                }
                HStack {
                    if model.companion.serviceEnabled { Button("Turn Off Local Connection") { model.disableCompanionService() }.disabled(!model.canConfigure) }
                    if model.companion.status.contains("Approval needed") { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
                }
            }
            Section("Command-line tools") {
                LabeledContent("Command tool", value: model.commandStatus?.state.rawValue ?? "Status unavailable")
                HStack {
                    Button("Install Command Tool") { model.installCommandTool() }.disabled(!model.canConfigure)
                    if model.commandStatus?.state == .installed { Button("Remove Command Tool") { model.removeCommandTool() }.disabled(!model.canConfigure || model.setupInProgress) }
                }
                Text("longhaul run -- command arguments").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text("Protects the supervised process until it exits. Detached child work requires explicit registration.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).task { await model.refreshIntegrationStatus() }
    }
}
