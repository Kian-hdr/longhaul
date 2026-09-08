import Foundation

/// Numeric reserve for a single closed-lid policy grant. Disabling this cutoff
/// does not disable sensor validity, OS battery warnings or thermal checks.
public struct LidBatteryPolicy: Codable, Sendable, Equatable {
    public var cutoffEnabled: Bool
    public var cutoffPercent: Int
    public init(cutoffEnabled: Bool = true, cutoffPercent: Int = 20) {
        self.cutoffEnabled = cutoffEnabled; self.cutoffPercent = cutoffPercent
    }
    public var isValid: Bool { (1...100).contains(cutoffPercent) }
}
