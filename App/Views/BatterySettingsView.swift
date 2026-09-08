import SwiftUI

struct BatterySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Battery reserve") {
                LabeledContent("Warn", value: "25% or 30 minutes")
                LabeledContent("Request checkpoints", value: "20% or 20 minutes")
                LabeledContent("Withdraw protection", value: model.closedLidEnabled
                               ? (model.lidBatteryPolicy.cutoffEnabled ? "Below \(model.lidBatteryPolicy.cutoffPercent)%" : "Battery auto-release off")
                               : "10% or 10 minutes")
                Text("The earliest credible trigger wins. OS warnings and thermal state can act sooner. Runtime estimates are uncertain, including when a weak charger is connected.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Recoverable progress") {
                Text("Supported integrations receive periodic and low-battery checkpoint requests. Longhaul records saved files and acknowledgement failures. Recovery must be verified in the source application.")
                Text("A sleeping Mac can still eventually run out of battery. Save durable work regularly.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
