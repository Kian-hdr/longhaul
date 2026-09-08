import SwiftUI
import LonghaulCore

/// A settings section edits bindings owned by AppModel; it owns no policy state.
struct ClosedLidSettingsSection: View {
    @Binding var enabled: Bool
    @Binding var batteryPolicy: LidBatteryPolicy
    let canConfigure: Bool
    let detail: String
    let saveEnabled: @MainActor () -> Void
    let saveBatteryPolicy: @MainActor () -> Void

    var body: some View {
        Section("Closed-lid protection") {
            Toggle("Continue reported jobs with the lid closed", isOn: $enabled)
                .onChange(of: enabled) { saveEnabled() }
                .disabled(!canConfigure)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Text("Experimental: attended testing on connected power only. Closed-lid battery and overnight operation remain unverified.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Battery auto-release", isOn: $batteryPolicy.cutoffEnabled)
                .onChange(of: batteryPolicy.cutoffEnabled) { saveBatteryPolicy() }
                .disabled(!canConfigure)
            LabeledContent("Release below", value: "\(batteryPolicy.cutoffPercent)%")
            Slider(value: Binding(get: { Double(batteryPolicy.cutoffPercent) }, set: {
                batteryPolicy.cutoffPercent = Int($0.rounded())
                saveBatteryPolicy()
            }), in: 1...100) { Text("Battery auto-release percentage") }
                .accessibilityValue("\(batteryPolicy.cutoffPercent) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: batteryPolicy.cutoffPercent = min(100, batteryPolicy.cutoffPercent + 1)
                    case .decrement: batteryPolicy.cutoffPercent = max(1, batteryPolicy.cutoffPercent - 1)
                    @unknown default: return
                    }
                    saveBatteryPolicy()
                }
                .disabled(!canConfigure || !batteryPolicy.cutoffEnabled)
            Text(batteryPolicy.cutoffEnabled
                 ? "Below \(batteryPolicy.cutoffPercent)%, Longhaul releases protection so macOS can sleep."
                 : "Longhaul will not release protection based on battery percentage or estimated time remaining.")
                .font(.callout).foregroundStyle(.secondary)
            Text("macOS battery and temperature safeguards still apply. Open the lid before starting protection.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
