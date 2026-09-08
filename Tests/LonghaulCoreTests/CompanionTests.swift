import Testing
import Foundation
@testable import LonghaulBridge
import LonghaulCore

private func companionSnapshot() -> CompanionSnapshot {
    .init(mode: "ready", reason: "Ready", protecting: false, enabled: true, jobs: [], batteryStage: "normal", batteryPercent: 80, checkpointSummary: nil, alerts: [])
}
@Test func companionRequiresLiveHostAndExplicitConnection() {
    var relay = CompanionRelayState()
    #expect(relay.exchange(.init(op: "hello"), host: false, now: 0).state == "Needs attention")
    let first = relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: false), host: true, now: 0)
    #expect(first.state == "Available")
    #expect(relay.exchange(.init(op: "pause", serverInstance: first.serverInstance), host: false, now: 1).state == "Needs attention")
    let connected = relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: true, now: 2)
    #expect(connected.state == "Connected")
    #expect(connected.snapshot?.instanceID == connected.serverInstance)
    #expect(relay.exchange(.init(op: "hello"), host: false, now: 11).snapshot == nil)
}
@Test func companionQueuesOnceAndAcknowledgesWithoutOptimisticState() {
    var relay = CompanionRelayState()
    let initial = relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: true, now: 0)
    let command = CompanionRequest(op: "pause", serverInstance: initial.serverInstance)
    let queued = relay.exchange(command, host: false, now: 1)
    #expect(queued.snapshot?.enabled == true)
    _ = relay.exchange(command, host: false, now: 1)
    let received = relay.exchange(.init(op: "hostUpdate", serverInstance: initial.serverInstance, snapshot: companionSnapshot(), paired: true), host: true, now: 2)
    #expect(received.commands?.count == 1)
    let ack = relay.exchange(.init(op: "hostUpdate", serverInstance: initial.serverInstance, snapshot: companionSnapshot(), paired: true, acknowledgedCommands: [command.requestID]), host: true, now: 3)
    #expect(ack.commands?.isEmpty == true)
    #expect((ack.snapshot?.revision ?? 0) > (initial.snapshot?.revision ?? 0))
}
@Test func companionRejectsOldEpochAndWrongSource() {
    var relay = CompanionRelayState()
    let start = relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: true, now: 0)
    #expect(relay.exchange(.init(op: "pause", serverInstance: "old"), host: false, now: 1).state == "Needs attention")
    var job = CompanionRequest(op: "job", serverInstance: start.serverInstance)
    job.job = .init(id: "worker", source: "Codex", title: "Spoofed job", phase: .completed)
    #expect(relay.exchange(job, host: false, now: 1).state == "Needs attention")
    job.job?.source = "Nodebay"
    #expect(relay.exchange(job, host: false, now: 1).state == "Connected")
    #expect(relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: false, now: 1).state == "Needs attention")
}
@Test func companionQueueAndMalformedSnapshotAreBounded() {
    var relay = CompanionRelayState()
    let start = relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: true, now: 0)
    for _ in 0..<64 { #expect(relay.exchange(.init(op: "pause", serverInstance: start.serverInstance), host: false, now: 1).state == "Connected") }
    #expect(relay.exchange(.init(op: "pause", serverInstance: start.serverInstance), host: false, now: 1).state == "Needs attention")
    var invalid = companionSnapshot(); invalid.batteryPercent = .nan
    #expect(relay.exchange(.init(op: "hostUpdate", snapshot: invalid, paired: true), host: true, now: 1).state == "Needs attention")
}

@Test func companionControlSurfaceCompatibilityAndValidation() throws {
    let legacy = try JSONEncoder().encode(companionSnapshot())
    #expect(try JSONDecoder().decode(CompanionSnapshot.self, from: legacy).controlSurface == nil)
    for surface in ControlSurface.allCases {
        var snapshot = companionSnapshot(); snapshot.controlSurface = surface.rawValue
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(CompanionSnapshot.self, from: data).controlSurface == surface.rawValue)
        var relay = CompanionRelayState()
        let result = relay.exchange(.init(op: "hostUpdate", snapshot: snapshot, paired: true), host: true, now: 0)
        #expect(result.snapshot?.controlSurface == surface.rawValue)
        #expect(result.snapshot?.enabled == true)
    }
    var invalid = companionSnapshot(); invalid.controlSurface = "hidden"
    var relay = CompanionRelayState()
    #expect(relay.exchange(.init(op: "hostUpdate", snapshot: invalid, paired: true), host: true, now: 0).state == "Needs attention")
    let legacyRequest = try JSONEncoder().encode(CompanionRequest(op: "hello"))
    #expect(try JSONDecoder().decode(CompanionRequest.self, from: legacyRequest).capabilities == nil)
    let legacyResponse = Data(#"{"version":1,"serverInstance":"legacy","state":"Available"}"#.utf8)
    #expect(try JSONDecoder().decode(CompanionResponse.self, from: legacyResponse).peerCapabilities == nil)
}

@Test func companionCapabilitiesExpireAndDoNotLeakToPeer() {
    var relay = CompanionRelayState()
    let host = CompanionRequest(op: "hostUpdate", snapshot: companionSnapshot(), paired: true)
    #expect(relay.exchange(host, host: true, now: 0).peerCapabilities == nil)
    var hello = CompanionRequest(op: "hello"); hello.capabilities = ["control-surface-v1"]
    #expect(relay.exchange(hello, host: false, now: 1).peerCapabilities == nil)
    #expect(relay.exchange(host, host: true, now: 2).peerCapabilities == ["control-surface-v1"])
    let expired = relay.exchange(host, host: true, now: 12)
    #expect(expired.peerActive == false)
    #expect(expired.peerCapabilities == nil)
    _ = relay.exchange(hello, host: false, now: 13)
    #expect(relay.exchange(host, host: true, now: 14).peerCapabilities == ["control-surface-v1"])
    _ = relay.exchange(.init(op: "status"), host: false, now: 15)
    #expect(relay.exchange(host, host: true, now: 16).peerCapabilities == [])
}

@Test func companionRejectsMalformedCapabilityAdvertisement() {
    var relay = CompanionRelayState()
    _ = relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: true, now: 0)
    for values in [[""], [String(repeating: "x", count: 81)], Array(repeating: "valid", count: 17)] {
        var request = CompanionRequest(op: "hello"); request.capabilities = values
        #expect(relay.exchange(request, host: false, now: 1).state == "Needs attention")
    }
    #expect(relay.exchange(.init(op: "hostUpdate", snapshot: companionSnapshot(), paired: true), host: true, now: 2).peerActive == false)
}
