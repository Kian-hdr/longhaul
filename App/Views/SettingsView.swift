import SwiftUI

/// Routes settings inside the app's existing unified window.
struct SettingsContent: View {
    let destination: AppDestination

    var body: some View {
        Group {
            switch destination {
            case .general: GeneralSettingsView()
            case .integrations: IntegrationsView()
            case .about: AboutView()
            case .battery: BatterySettingsView()
            case .diagnostics: DiagnosticsSettingsView()
            default: EmptyView()
            }
        }
    }
}
