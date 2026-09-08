import Foundation

public enum ControlSurface: String, Codable, CaseIterable, Sendable {
    case nodebay
    case menuBar

    public var title: String { self == .nodebay ? "Nodebay" : "Menu Bar" }

    public static func preferred(saved: Self?, nodebayInstalled: Bool) -> Self {
        saved ?? (nodebayInstalled ? .nodebay : .menuBar)
    }

    public func usesMenuBar(nodebayInstalled: Bool, paired: Bool, linked: Bool, routingSupported: Bool) -> Bool {
        self == .menuBar || !nodebayInstalled || !paired || !linked || !routingSupported
    }
}
