import Foundation

enum AppDestination: String, CaseIterable, Identifiable {
    case activity, history, recovery, general, integrations, battery, diagnostics, about

    var id: String { rawValue }
    static let work: [Self] = [.activity, .history, .recovery]
    static let settings: [Self] = [.general, .integrations, .battery, .diagnostics, .about]
    var isSettings: Bool { Self.settings.contains(self) }
    var title: String {
        switch self {
        case .activity: "Activity"
        case .history: "History"
        case .recovery: "Recovery"
        case .general: "General"
        case .integrations: "Integrations"
        case .battery: "Battery & Recovery"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .activity: "bolt.shield"
        case .history: "clock"
        case .recovery: "externaldrive.badge.checkmark"
        case .general: "gearshape"
        case .integrations: "puzzlepiece.extension"
        case .battery: "battery.50percent"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}
