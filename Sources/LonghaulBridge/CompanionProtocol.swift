import Foundation
import LonghaulCore

@objc(LonghaulCompanionProtocol)
public protocol LonghaulCompanionProtocol {
    func exchange(_ data: Data, with reply: @escaping (Data) -> Void)
}

public enum CompanionIdentity {
    public static let service = "space.exlumina.longhaul.companion"
    public static let host = "space.exlumina.longhaul"
    public static let nodebay = "theboringteam.boringnotch.BoringNotchXPCHelper"
    public static func requirement(_ identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"HZWY8HT54D\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }
}

public struct CompanionAlert: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    public init(id: String = UUID().uuidString, title: String, body: String) { self.id = id; self.title = title; self.body = body }
}
public struct CompanionSnapshot: Codable, Sendable {
    public struct Job: Codable, Sendable {
        public var id: String; public var title: String; public var phase: String; public var progress: Double?
        public init(_ event: JobEvent) { id = event.source + ":" + event.id; title = event.title; phase = event.phase.rawValue; progress = event.progress }
    }
    public var instanceID = "host"
    public var revision = 0
    public var mode: String
    public var reason: String
    public var protecting: Bool
    public var enabled: Bool
    public var controlSurface: String? = nil
    public var jobCount: Int
    public var jobs: [Job]
    public var batteryStage: String
    public var batteryPercent: Double?
    public var checkpointSummary: String?
    public var alerts: [CompanionAlert]
    public init(mode: String, reason: String, protecting: Bool, enabled: Bool, jobs: [Job], batteryStage: String, batteryPercent: Double?, checkpointSummary: String?, alerts: [CompanionAlert]) {
        self.mode = mode; self.reason = reason; self.protecting = protecting; self.enabled = enabled; self.jobCount = jobs.count
        self.jobs = Array(jobs.prefix(100)); self.batteryStage = batteryStage; self.batteryPercent = batteryPercent
        self.checkpointSummary = checkpointSummary; self.alerts = Array(alerts.prefix(32))
    }
    public var isValid: Bool {
        (controlSurface == nil || ControlSurface(rawValue: controlSurface!) != nil) &&
        jobs.count <= 100 && alerts.count <= 32 && (0...10_000).contains(jobCount) && reason.utf8.count <= 1024 && mode.utf8.count <= 80 &&
        ["normal", "warning", "prepare", "critical"].contains(batteryStage) &&
        (batteryPercent == nil || (batteryPercent!.isFinite && (0...100).contains(batteryPercent!))) &&
        (checkpointSummary?.utf8.count ?? 0) <= 2048 &&
        jobs.allSatisfy { !$0.id.isEmpty && $0.id.utf8.count <= 300 && $0.title.utf8.count <= 240 && $0.phase.utf8.count <= 80 && ($0.progress == nil || ($0.progress!.isFinite && (0...1).contains($0.progress!))) } &&
        alerts.allSatisfy { !$0.id.isEmpty && $0.id.utf8.count <= 180 && $0.title.utf8.count <= 240 && $0.body.utf8.count <= 2048 }
    }
}
public struct CompanionRequest: Codable, Sendable {
    public var version = 1
    public var requestID = UUID().uuidString
    public var op: String
    public var serverInstance: String?
    public var minutes: Int?
    public var job: JobEvent?
    public var alertID: String?
    public var snapshot: CompanionSnapshot?
    public var paired: Bool?
    public var acknowledgedCommands: [String]?
    public var capabilities: [String]? = nil
    public init(op: String, serverInstance: String? = nil, snapshot: CompanionSnapshot? = nil, paired: Bool? = nil, acknowledgedCommands: [String]? = nil) {
        self.op = op; self.serverInstance = serverInstance; self.snapshot = snapshot; self.paired = paired; self.acknowledgedCommands = acknowledgedCommands
    }
}
public struct CompanionResponse: Codable, Sendable {
    public var version = 1
    public var serverInstance: String
    public var state: String
    public var message: String?
    public var snapshot: CompanionSnapshot?
    public var commands: [CompanionRequest]?
    public var peerActive: Bool? = nil
    public var peerCapabilities: [String]? = nil
}

/// Serialized by the relay. No power ownership or process execution occurs here.
public struct CompanionRelayState: Sendable {
    public let instance = UUID().uuidString
    public private(set) var snapshot: CompanionSnapshot?
    private var revision = 0
    private var lastHost: TimeInterval = -.infinity
    private var lastPeer: TimeInterval = -.infinity
    private var peerCapabilities: [String] = []
    private var paired = false
    private var queue: [CompanionRequest] = []
    private var recent: [String] = []
    public init() {}
    public mutating func exchange(_ request: CompanionRequest, host: Bool, now: TimeInterval) -> CompanionResponse {
        func response(_ state: String, _ message: String? = nil, commands: [CompanionRequest]? = nil) -> CompanionResponse {
            .init(serverInstance: instance, state: state, message: message, snapshot: state == "Connected" ? snapshot : nil, commands: commands, peerActive: now - lastPeer <= 10,
                  peerCapabilities: host && now - lastPeer <= 10 ? peerCapabilities : nil)
        }
        guard request.version == 1, UUID(uuidString: request.requestID) != nil,
              (request.capabilities?.count ?? 0) <= 16,
              request.capabilities?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 80 }) ?? true else { return response("Needs attention", "Unsupported local request.") }
        if host {
            guard request.op == "hostUpdate", let new = request.snapshot, new.isValid, let linked = request.paired,
                  (request.acknowledgedCommands?.count ?? 0) <= 64 else { return response("Needs attention", "Invalid host status.") }
            if request.serverInstance == instance {
                let acknowledged = Set(request.acknowledgedCommands ?? [])
                queue.removeAll { acknowledged.contains($0.requestID) }
            }
            revision += 1; snapshot = new; snapshot?.instanceID = instance; snapshot?.revision = revision
            lastHost = now; paired = linked
            return response(paired ? "Connected" : "Available", commands: queue)
        }
        guard now - lastHost <= 8, snapshot != nil else { return response("Needs attention", "Open Longhaul to restore the connection.") }
        if ["hello", "status"].contains(request.op) {
            lastPeer = now
            peerCapabilities = request.capabilities ?? []
            return response(paired ? "Connected" : "Available")
        }
        guard request.serverInstance == instance else { return response("Needs attention", "The connection restarted. Reconnect before sending controls.") }
        guard ["connect", "disconnect", "pause", "resume", "keepAwake", "job", "ackAlert"].contains(request.op),
              paired || request.op == "connect",
              request.op != "keepAwake" || [30, 60, 240].contains(request.minutes ?? 0),
              request.op != "job" || (request.job?.isValid == true && request.job?.source == "Nodebay"),
              request.op != "ackAlert" || ((request.alertID?.utf8.count ?? 0) > 0 && (request.alertID?.utf8.count ?? 0) <= 180),
              request.snapshot == nil, request.paired == nil, request.acknowledgedCommands == nil else {
            return response("Needs attention", "This control is not available.")
        }
        if !recent.contains(request.requestID) {
            guard queue.count < 64 else { return response("Needs attention", "Longhaul is catching up. Try again shortly.") }
            queue.append(request); recent.append(request.requestID); recent = Array(recent.suffix(1024))
        }
        return response(paired ? "Connected" : "Available", "Request queued; awaiting Longhaul.")
    }
}
