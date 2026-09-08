import AppKit
import SwiftUI
import OSLog

/// Owns the status item independently of SwiftUI scene reconstruction.
/// Protection and the selected location remain owned by AppModel.
@MainActor final class MenuBarController: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private weak var model: AppModel?
    private let logger = Logger(subsystem: "space.exlumina.longhaul", category: "MenuBar")
    private var lastSymbol: String?

    init(model: AppModel) {
        self.model = model
        super.init()
        let content = StatusPopover(openMain: { [weak self] settings in
            self?.popover.performClose(nil)
            if settings { self?.model?.showSettings() }
            // Launch Services reopens the existing singleton scene, including
            // after its last window has been closed.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }).environment(model)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    func update(visible: Bool, symbol: String, summary: String) {
        if visible && item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "Longhaul.Controls"
            item.behavior = []
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.setAccessibilityLabel("Longhaul")
            item.button?.setAccessibilityIdentifier("LonghaulMenuBar")
            self.item = item
            logger.info("Created status item")
        }
        guard let item else { return }
        if item.isVisible != visible {
            if !visible { popover.performClose(nil) }
            item.isVisible = visible
            logger.info("Status item visible: \(visible, privacy: .public)")
        }
        if lastSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Longhaul")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            item.button?.image = image
            lastSymbol = symbol
        }
        item.button?.toolTip = "Longhaul · " + summary
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let item, item.isVisible, let button = item.button, button.window != nil else {
            model?.error = "The menu-bar control is unavailable. Select Menu Bar again to restore it."
            logger.error("Cannot open popover without a visible status item")
            return
        }
        // Explicit appearance is used by isolated previews; nil retains native adaptation.
        popover.appearance = NSApp.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        logger.info("Opened status-item popover; shown: \(self.popover.isShown, privacy: .public)")
        model?.record("Menu bar", "Controls opened from the status item")
    }

    func popoverDidClose(_ notification: Notification) {
        logger.info("Closed status-item popover")
    }

    func stop() {
        popover.performClose(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        popover.contentViewController = nil
        logger.info("Removed status item")
    }
}
