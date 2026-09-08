import SwiftUI
import AppKit

@MainActor struct LonghaulCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandGroup(replacing: .appInfo) {
            Button("About Longhaul") {
                model.navigate(to: .about)
                openMain()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.showSettings()
                openMain()
            }.keyboardShortcut(",")
        }
        CommandGroup(after: .sidebar) {
            ForEach(AppDestination.allCases) { destination in
                Button(destination.title) {
                    model.navigate(to: destination)
                    openMain()
                }
            }
        }
        CommandMenu("Protection") {
            Button(model.settings.enabled ? "Pause Automation" : "Resume Automation") { model.toggleAutomation() }
            Menu("Keep Awake") {
                Button("For 30 Minutes") { model.keepAwake(minutes: 30) }
                Button("For 1 Hour") { model.keepAwake(minutes: 60) }
                Button("For 4 Hours") { model.keepAwake(minutes: 240) }
            }
            Button("End Manual Session") { model.endManual() }
            Divider()
            Button("Export Diagnostics…") { model.exportHistory() }
        }
    }
    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
