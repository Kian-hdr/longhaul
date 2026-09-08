import Foundation
import ServiceManagement
import Observation
import LonghaulBridge

@MainActor @Observable
final class CompanionBridge {
    var status = "Off"
    var linked = false
    var serviceEnabled = false
    var nodebayInstalled = false
    var supportsControlSurface = false
    @ObservationIgnored private var instance: String?
    @ObservationIgnored private var acknowledged: [String] = []
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var nextAttempt = Date.distantPast
    private var service: SMAppService { .agent(plistName: CompanionIdentity.service + ".plist") }
    init() { refreshStatus() }
    func refreshStatus() {
        serviceEnabled = service.status == .enabled
        if !serviceEnabled {
            linked = false; supportsControlSurface = false
            status = service.status == .requiresApproval ? "Approval needed in Login Items" : "Off"
        }
    }
    func register() throws { try service.register(); refreshStatus(); nextAttempt = .distantPast }
    func unregister() throws { try service.unregister(); refreshStatus(); instance = nil; acknowledged = [] }
    func stop() { stopped = true }
    func update(_ snapshot: CompanionSnapshot, paired: Bool) async -> [CompanionRequest] {
        guard !pending, !stopped, serviceEnabled, Date() >= nextAttempt else { return [] }
        pending = true; defer { pending = false }
        do {
            let request = CompanionRequest(op: "hostUpdate", serverInstance: instance, snapshot: snapshot, paired: paired, acknowledgedCommands: acknowledged)
            let data = try JSONEncoder().encode(request)
            let responseData = try await CompanionTransport.exchange(data)
            guard !stopped, responseData.count <= 65_536 else { return [] }
            let response = try JSONDecoder().decode(CompanionResponse.self, from: responseData)
            guard response.version == 1, !response.serverInstance.isEmpty, (response.commands?.count ?? 0) <= 64,
                  (response.peerCapabilities?.count ?? 0) <= 16,
                  response.peerCapabilities?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 80 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
            if instance != response.serverInstance { acknowledged = [] }
            instance = response.serverInstance
            linked = response.state == "Connected" && response.peerActive == true
            supportsControlSurface = linked && response.peerCapabilities?.contains("control-surface-v1") == true
            status = response.state == "Connected" && !linked ? "Waiting for Nodebay" : response.state
            return response.commands ?? []
        } catch {
            status = "Needs attention: local connection unavailable"; linked = false; supportsControlSurface = false
            nextAttempt = Date().addingTimeInterval(10); return []
        }
    }
    func acknowledge(_ id: String) { acknowledged.append(id); acknowledged = Array(acknowledged.suffix(64)) }
}

private enum CompanionTransport {
    static func exchange(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: CompanionIdentity.service, options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: LonghaulCompanionProtocol.self)
            connection.setCodeSigningRequirement(CompanionIdentity.requirement(CompanionIdentity.service))
            let gate = CompanionReplyGate(connection: connection, continuation: continuation)
            connection.invalidationHandler = { gate.finish(.failure(CocoaError(.xpcConnectionInvalid))) }
            connection.interruptionHandler = { gate.finish(.failure(CocoaError(.xpcConnectionInterrupted))) }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in gate.finish(.failure(CocoaError(.xpcConnectionInvalid))) }) as? LonghaulCompanionProtocol else {
                gate.finish(.failure(CocoaError(.xpcConnectionInvalid))); return
            }
            proxy.exchange(data) { value in
                guard connection.effectiveUserIdentifier == geteuid(), value.count <= 65_536 else { gate.finish(.failure(CocoaError(.coderReadCorrupt))); return }
                gate.finish(.success(value))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { gate.finish(.failure(CocoaError(.xpcConnectionInterrupted))) }
        }
    }
}
private final class CompanionReplyGate: @unchecked Sendable {
    let connection: NSXPCConnection
    let lock = NSLock()
    var continuation: CheckedContinuation<Data, Error>?
    init(connection: NSXPCConnection, continuation: CheckedContinuation<Data, Error>) { self.connection = connection; self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        let value = lock.withLock { let value = continuation; continuation = nil; return value }
        guard let value else { return }
        connection.invalidationHandler = nil; connection.interruptionHandler = nil
        connection.invalidate(); value.resume(with: result)
    }
}
