import Foundation
import Security
import Darwin
import LonghaulBridge

final class Relay: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private var state = CompanionRelayState()
    private let lock = NSLock()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        let isHost = Self.matches(connection, identifier: CompanionIdentity.host)
        guard isHost || Self.matches(connection, identifier: CompanionIdentity.nodebay) else { return false }
        connection.setCodeSigningRequirement(CompanionIdentity.requirement(isHost ? CompanionIdentity.host : CompanionIdentity.nodebay))
        connection.exportedInterface = NSXPCInterface(with: LonghaulCompanionProtocol.self)
        connection.exportedObject = Peer(relay: self, host: isHost)
        connection.resume(); return true
    }
    private static func matches(_ connection: NSXPCConnection, identifier: String) -> Bool {
        var code: SecCode?; var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(CompanionIdentity.requirement(identifier) as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    func exchange(_ data: Data, host: Bool) -> Data {
        lock.withLock {
            guard data.count <= 65_536, let request = try? JSONDecoder().decode(CompanionRequest.self, from: data) else { return Data() }
            let response = state.exchange(request, host: host, now: ProcessInfo.processInfo.systemUptime)
            guard let output = try? JSONEncoder().encode(response), output.count <= 65_536 else { return Data() }
            return output
        }
    }
}
final class Peer: NSObject, LonghaulCompanionProtocol {
    let relay: Relay; let host: Bool
    init(relay: Relay, host: Bool) { self.relay = relay; self.host = host }
    func exchange(_ data: Data, with reply: @escaping (Data) -> Void) { reply(relay.exchange(data, host: host)) }
}
let relay = Relay()
let listener = NSXPCListener(machServiceName: CompanionIdentity.service)
listener.setConnectionCodeSigningRequirement("(" + CompanionIdentity.requirement(CompanionIdentity.host) + ") or (" + CompanionIdentity.requirement(CompanionIdentity.nodebay) + ")")
listener.delegate = relay
listener.resume()
RunLoop.main.run()
