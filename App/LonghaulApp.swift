import SwiftUI
import AppKit
import CoreServices

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.model?.startMenuBar()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let login = event?.eventID == kAEOpenApplication &&
            (event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem ||
             event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true)
        if login || CommandLine.arguments.contains("--background") {
            for window in NSApp.windows where window.title == "Longhaul" { window.orderOut(nil) }
            Self.model?.record("Lifecycle", "Background launch; activity window hidden")
        }
        // Suppression also affects future Finder/Spotlight reopen events. Once
        // launch is finished, restore the scene's normal presentation behavior.
        DispatchQueue.main.async { Self.model?.suppressInitialWindow = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let visible = NSApp.windows.contains { $0.title == "Longhaul" && $0.isVisible }
            Self.model?.record("Lifecycle", "Launch settled; activity window \(visible ? "visible" : "hidden")")
        }
        if CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--data-directory"),
           let index = CommandLine.arguments.firstIndex(of: "--appearance"), index + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.model?.stop(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await Self.model?.refreshNotificationStatus() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.title == "Longhaul" }) { window.makeKeyAndOrderFront(nil); sender.activate() }
        return true
    }
}

@main struct LonghaulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }
    var body: some Scene {
        Window("Longhaul", id: "main") {
            ContentView().environment(model)
                .frame(minWidth: 620, minHeight: 420)

        }
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(model.suppressInitialWindow ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands { LonghaulCommands(model: model) }
    }
}
