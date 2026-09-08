import Foundation

/// Cooperative GUI resources. App-wide reservations conflict with every window
/// of that app. Window independence is an explicit, trusted broker qualification.
public enum CoordinationResource: Codable, Hashable, Sendable {
    case application(String)
    case window(application: String, instance: String, window: String)
    case browserProfile(application: String, profile: String)
    case browserSession(application: String, profile: String, session: String)
    case foreground, clipboard, desktop

    fileprivate var valid: Bool {
        func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 180 && !value.contains("\0") }
        switch self {
        case .application(let a): return valid(a)
        case .browserProfile(let a, let p): return valid(a) && valid(p)
        case .window(let a, let i, let w): return valid(a) && valid(i) && valid(w)
        case .browserSession(let a, let p, let s): return valid(a) && valid(p) && valid(s)
        case .foreground, .clipboard, .desktop: return true
        }
    }
    fileprivate func conflicts(with other: Self) -> Bool {
        switch (self, other) {
        case (.desktop, _), (_, .desktop): return true
        case (.application(let a), .application(let b)): return a == b
        case (.application(let a), .window(let b, _, _)), (.window(let b, _, _), .application(let a)): return a == b
        case (.window(let a, let i, let w), .window(let b, let j, let x)): return a == b && i == j && w == x
        case (.application(let a), .browserProfile(let b, _)), (.browserProfile(let b, _), .application(let a)),
             (.application(let a), .browserSession(let b, _, _)), (.browserSession(let b, _, _), .application(let a)):
            return a == b
        case (.window(let a, _, _), .browserProfile(let b, _)), (.browserProfile(let b, _), .window(let a, _, _)),
             (.window(let a, _, _), .browserSession(let b, _, _)), (.browserSession(let b, _, _), .window(let a, _, _)):
            return a == b
        case (.browserProfile(let a, let p), .browserProfile(let b, let q)): return a == b && p == q
        case (.browserProfile(let a, let p), .browserSession(let b, let q, _)), (.browserSession(let b, let q, _), .browserProfile(let a, let p)):
            return a == b && p == q
        case (.browserSession(let a, let p, let i), .browserSession(let b, let q, let j)): return a == b && p == q && i == j
        case (.foreground, .foreground), (.clipboard, .clipboard): return true
        default: return false
        }
    }
}

public struct CoordinationClient: Codable, Equatable, Sendable {
    public let id: String
    public let incarnation: String
    public let epoch: String
}

public enum CoordinationActionOutcome: String, Codable, Sendable { case completed, indeterminate }
public enum CoordinationOperation: Codable, Equatable, Sendable {
    case reserve(taskID: String, resources: [CoordinationResource], leaseSeconds: Double = 15)
    case poll(ticketID: String)
    case cancel(ticketID: String)
    case renew(permitID: String, fence: Int, leaseSeconds: Double = 15)
    case beginAction(permitID: String, fence: Int, observedAt: TimeInterval)
    case endAction(actionID: String, outcome: CoordinationActionOutcome)
    case release(permitID: String, fence: Int)
    case disconnect
}

public struct CoordinationEnvelope: Codable, Equatable, Sendable {
    public var version = 1
    public var requestID: String
    public var client: CoordinationClient
    public var sequence: Int
    public var operation: CoordinationOperation
    public init(client: CoordinationClient, sequence: Int, operation: CoordinationOperation, requestID: String = UUID().uuidString) {
        self.client = client; self.sequence = sequence; self.operation = operation; self.requestID = requestID
    }
}

public struct CoordinationPermit: Codable, Equatable, Sendable {
    public let id: String
    public let epoch: String
    public let clientID: String
    public let taskID: String
    public let fence: Int
    public let resources: [CoordinationResource]
    public let grantedAt: TimeInterval
    public var expiresAt: TimeInterval
    public let hardDeadline: TimeInterval
    /// A cooperating executor must observe the target after this instant. A
    /// timestamp declaration alone is not proof that native CUA observed it.
    public var observationAfter: TimeInterval
}

public struct CoordinationAction: Codable, Equatable, Sendable {
    public let id: String
    public let permitID: String
    public let epoch: String
    public let fence: Int
}

public enum CoordinationDisposition: String, Codable, Sendable {
    case granted, queued, cancelled, released, revoked, fenced
    case renewed, actionBegan, actionEnded, disconnected, duplicate, denied
}
public enum CoordinationActivity: String, Codable, Sendable {
    case idle, workingInBackground, workingInForeground, waitingForAppAccess
    case yieldingToHuman, paused, needsAttention, unavailable
}
public enum CoordinationFailure: String, Error, Codable, Sendable {
    case invalidInput, unsupportedVersion, staleEpoch, unauthenticated, staleSequence
    case requestIDReused, limitReached, unknownTicket, invalidPermit, observationRequired
    case actionInFlight, resourcesFenced, invalidClock
}
public struct CoordinationReply: Codable, Equatable, Sendable {
    public var disposition: CoordinationDisposition
    public var activity: CoordinationActivity
    public var ticketID: String?
    public var permit: CoordinationPermit?
    public var action: CoordinationAction?
    public var failure: CoordinationFailure?
    public var message: String
    public var retryAfter: Double?
}
public struct CoordinationFence: Codable, Equatable, Sendable {
    public let id: String
    public let ownerClientID: String?
    public let resources: [CoordinationResource]
    public let reason: String
}
public struct CoordinationSnapshot: Codable, Sendable {
    public let epoch: String
    public let revision: Int
    public let reservations: [CoordinationReply]
    public let fences: [CoordinationFence]
    public let humanPriority: [CoordinationResource]
}
public enum CoordinationSafeReleaseEvidence: String, Codable, Sendable {
    case executorConfirmedStopped, actionConfirmedComplete, userConfirmedSafe
}

/// Pure, serialized state machine. The hosting transport must authenticate
/// `principal`, own its clock, persist/reconcile restart state, and restrict host
/// control methods. No method here intercepts or executes native UI input.
public struct CoordinationBroker: Codable, Sendable {
    private struct ClientRecord: Codable, Sendable {
        var handle: CoordinationClient
        var principal: String
        var active = true
        var sequence = -1
        var lastSeen: TimeInterval
    }
    private struct Ticket: Codable, Sendable {
        var id: String
        var clientID: String
        var taskID: String
        var resources: [CoordinationResource]
        var lease: Double
        var order: Int
        var queueExpiresAt: TimeInterval
        var disposition: CoordinationDisposition = .queued
        var permit: CoordinationPermit?
        var reason = "Waiting for app access."
    }
    private struct Hold: Codable, Sendable {
        var permit: CoordinationPermit
        var ticketID: String
        var action: CoordinationAction?
        var fenceReason: String?
    }
    private struct Handled: Codable, Sendable {
        var request: CoordinationEnvelope
        var ticketID: String?
    }
    public private(set) var epoch: String
    public private(set) var revision = 0
    private var now: TimeInterval = 0
    private var order = 0
    private var token = 0
    private var clients: [String: ClientRecord] = [:]
    private var tickets: [String: Ticket] = [:]
    private var holds: [String: Hold] = [:]
    private var restartFences: [String: CoordinationFence] = [:]
    private var human: [CoordinationResource] = []
    private var handled: [Handled] = []
    private let qualifiedWindowApplications: Set<String>

    /// Cold start is fenced by default because a new process cannot know whether
    /// a previous executor is still acting. A clean, isolated fixture can opt out.
    public init(epoch: String = UUID().uuidString, initiallyFenced: Bool = true,
                qualifiedWindowApplications: Set<String> = []) {
        self.epoch = epoch; self.qualifiedWindowApplications = qualifiedWindowApplications
        if initiallyFenced {
            let id = UUID().uuidString
            restartFences[id] = .init(id: id, ownerClientID: nil, resources: [.desktop], reason: "Reconcile prior executors before granting app access.")
        }
    }

    public mutating func register(principal: String, incarnation: String, now time: TimeInterval) throws -> CoordinationClient {
        try advance(to: time)
        guard valid(principal), valid(incarnation) else { throw CoordinationFailure.invalidInput }
        if let record = clients.values.first(where: { $0.active && $0.principal == principal && $0.handle.incarnation == incarnation }) { return record.handle }
        for record in clients.values.filter({ $0.active && $0.principal == principal }) { disconnect(record.handle.id, reason: "The participating client restarted.") }
        clients = clients.filter { id, record in record.active || holds.values.contains(where: { $0.permit.clientID == id }) }
        guard clients.count < 128 else { throw CoordinationFailure.limitReached }
        let client = CoordinationClient(id: UUID().uuidString, incarnation: incarnation, epoch: epoch)
        clients[client.id] = .init(handle: client, principal: principal, lastSeen: now)
        revision += 1; promote()
        return client
    }

    public mutating func exchange(_ request: CoordinationEnvelope, authenticatedPrincipal: String, now time: TimeInterval) -> CoordinationReply {
        do { try advance(to: time) } catch { return denied(.invalidClock) }
        guard request.version == 1 else { return denied(.unsupportedVersion) }
        guard request.client.epoch == epoch else { return denied(.staleEpoch) }
        guard let client = clients[request.client.id], client.handle == request.client,
              client.principal == authenticatedPrincipal else { return denied(.unauthenticated) }
        guard UUID(uuidString: request.requestID) != nil, request.sequence >= 0, request.sequence <= 9_007_199_254_740_990,
              validOperation(request.operation) else { return denied(.invalidInput) }
        if let previous = handled.first(where: { $0.request.requestID == request.requestID }) {
            guard previous.request == request else { return denied(.requestIDReused) }
            // In particular, a lost beginAction reply must never authorize a
            // second execution. The caller must reconcile the existing action.
            return .init(disposition: .duplicate, activity: .needsAttention, ticketID: previous.ticketID,
                         message: "Already handled. Do not execute an action again; poll or reconcile its result.")
        }
        guard client.active else { return denied(.unauthenticated) }
        guard request.sequence > client.sequence else { return denied(.staleSequence) }
        clients[client.handle.id]?.sequence = request.sequence
        clients[client.handle.id]?.lastSeen = now
        let result = perform(request.operation, client: client.handle.id)
        handled.append(.init(request: request, ticketID: result.ticketID))
        handled = Array(handled.suffix(1_024))
        return result
    }

    /// Host clock only. Expiry frees an idle permit, but never an in-flight action.
    public mutating func advance(to time: TimeInterval) throws {
        guard time.isFinite, time >= now else { throw CoordinationFailure.invalidClock }
        now = time
        for ticket in tickets.values where ticket.disposition == .queued && ticket.queueExpiresAt <= now {
            tickets[ticket.id]?.disposition = .cancelled
            tickets[ticket.id]?.reason = "Queue lease expired. Request access again and make a fresh observation."
            revision += 1
        }
        for hold in holds.values where hold.permit.expiresAt <= now && hold.fenceReason == nil {
            if hold.action != nil { fence(hold.permit.id, reason: "Lease expired while an action may still be executing.") }
            else { remove(hold.permit.id, disposition: .revoked, reason: "The unused permit expired.") }
        }
        for client in clients.values where client.active && now - client.lastSeen >= 60 &&
            !holds.values.contains(where: { $0.permit.clientID == client.handle.id }) &&
            !tickets.values.contains(where: { $0.clientID == client.handle.id && $0.disposition == .queued }) {
            clients[client.handle.id]?.active = false
            revision += 1
        }
        promote()
    }

    /// Trusted user control, separate from untrusted participant requests. Empty
    /// resources resume grants, without reviving revoked permits or stale actions.
    public mutating func setHumanPriority(_ resources: [CoordinationResource], now time: TimeInterval) throws {
        try advance(to: time)
        guard resources.count <= 16, resources.allSatisfy(\.valid) else { throw CoordinationFailure.invalidInput }
        human = normalized(resources)
        for hold in holds.values where conflicts(hold.permit.resources, human) {
            if hold.action != nil { fence(hold.permit.id, reason: "Yielding to the human; waiting for the executing action to stop.") }
            else { remove(hold.permit.id, disposition: .revoked, reason: "The human has priority. Obtain a new permit and observation.") }
        }
        revision += 1; promote()
    }

    /// The host must verify the evidence externally. A heartbeat loss, timeout or
    /// empty process list supplied by the agent is not confirmation of safety.
    public mutating func confirmSafeRelease(fenceID: String, evidence: CoordinationSafeReleaseEvidence, now time: TimeInterval) throws {
        try advance(to: time)
        if restartFences.removeValue(forKey: fenceID) != nil { revision += 1; promote(); return }
        guard holds[fenceID]?.fenceReason != nil else { throw CoordinationFailure.invalidPermit }
        remove(fenceID, disposition: .released, reason: "Safe release confirmed: \(evidence.rawValue).")
        promote()
    }

    /// Restore a persisted broker, then call this before serving clients. All old
    /// held resources are fenced until reconciled, and every old token is invalid.
    public mutating func restart(now time: TimeInterval) throws {
        guard time.isFinite, time >= 0 else { throw CoordinationFailure.invalidClock }
        now = time
        for hold in holds.values {
            restartFences[hold.permit.id] = .init(id: hold.permit.id, ownerClientID: hold.permit.clientID,
                resources: hold.permit.resources, reason: "Broker restarted. Reconcile the previous executor.")
        }
        if restartFences.count > 256 {
            let id = UUID().uuidString
            restartFences = [id: .init(id: id, ownerClientID: nil, resources: [.desktop], reason: "Reconcile all previous executors before resuming app access.")]
        }
        epoch = UUID().uuidString
        clients.removeAll(); tickets.removeAll(); holds.removeAll(); handled.removeAll()
        token = 0; order = 0; revision += 1
    }

    public func snapshot() -> CoordinationSnapshot {
        let active = tickets.values.filter { [.queued, .granted, .fenced].contains($0.disposition) }.sorted { $0.order < $1.order }
        let quarantined = holds.values.compactMap { hold -> CoordinationFence? in
            guard let reason = hold.fenceReason else { return nil }
            return .init(id: hold.permit.id, ownerClientID: hold.permit.clientID, resources: hold.permit.resources, reason: reason)
        }
        return .init(epoch: epoch, revision: revision, reservations: active.map(reply),
                     fences: (Array(restartFences.values) + quarantined).sorted { $0.id < $1.id }, humanPriority: human)
    }

    private mutating func perform(_ operation: CoordinationOperation, client: String) -> CoordinationReply {
        switch operation {
        case .reserve(let task, let resources, let lease):
            guard valid(task), !resources.isEmpty, resources.count <= 16, resources.allSatisfy(\.valid), validLease(lease) else { return denied(.invalidInput) }
            let open = tickets.values.filter { $0.clientID == client && [.queued, .granted, .fenced].contains($0.disposition) }
            guard open.count < 8, tickets.values.filter({ $0.disposition == .queued }).count < 128, holds.count < 128 else { return denied(.limitReached) }
            if tickets.count >= 512 { tickets = tickets.filter { [.queued, .granted, .fenced].contains($0.value.disposition) } }
            order += 1
            let ticket = Ticket(id: UUID().uuidString, clientID: client, taskID: task, resources: normalized(resources), lease: lease, order: order, queueExpiresAt: now + 30)
            tickets[ticket.id] = ticket; revision += 1; promote()
            return reply(tickets[ticket.id]!)
        case .poll(let id):
            guard let ticket = tickets[id], ticket.clientID == client else { return denied(.unknownTicket) }
            if ticket.disposition == .queued { tickets[id]?.queueExpiresAt = now + 30 }
            return reply(ticket)
        case .cancel(let id):
            guard var ticket = tickets[id], ticket.clientID == client else { return denied(.unknownTicket) }
            if ticket.disposition == .cancelled { return reply(ticket) }
            guard ticket.disposition == .queued else { return denied(.invalidPermit, "Use release for a granted permit; an action may still be running.") }
            ticket.disposition = .cancelled; ticket.reason = "Queued request cancelled."; tickets[id] = ticket
            revision += 1; promote(); return reply(ticket)
        case .renew(let id, let token, let lease):
            guard var hold = owned(id, fence: token, client: client), hold.fenceReason == nil else { return denied(.invalidPermit) }
            guard validLease(lease), now < hold.permit.hardDeadline else { return denied(.invalidInput) }
            hold.permit.expiresAt = min(now + lease, hold.permit.hardDeadline)
            holds[id] = hold; tickets[hold.ticketID]?.permit = hold.permit; revision += 1
            var result = reply(tickets[hold.ticketID]!); result.disposition = .renewed; return result
        case .beginAction(let id, let token, let observation):
            guard var hold = owned(id, fence: token, client: client) else { return denied(.invalidPermit) }
            guard hold.fenceReason == nil, !conflicts(hold.permit.resources, human) else { return denied(.resourcesFenced) }
            guard hold.action == nil else { return denied(.actionInFlight) }
            guard observation.isFinite, observation >= hold.permit.observationAfter, observation <= now else { return denied(.observationRequired) }
            let action = CoordinationAction(id: UUID().uuidString, permitID: id, epoch: epoch, fence: token)
            hold.action = action; holds[id] = hold; revision += 1
            var result = reply(tickets[hold.ticketID]!); result.disposition = .actionBegan; result.action = action; return result
        case .endAction(let id, let outcome):
            guard let hold = holds.values.first(where: { $0.permit.clientID == client && $0.action?.id == id }) else { return denied(.invalidPermit) }
            if outcome == .indeterminate {
                fence(hold.permit.id, reason: "Action result is indeterminate. Confirm it stopped before reassigning this resource.")
                return reply(tickets[hold.ticketID]!)
            }
            if hold.fenceReason != nil || hold.permit.expiresAt <= now {
                remove(hold.permit.id, disposition: .released, reason: "The executing action confirmed completion after yielding.")
                promote(); return reply(tickets[hold.ticketID]!)
            }
            holds[hold.permit.id]?.action = nil
            holds[hold.permit.id]?.permit.observationAfter = now
            tickets[hold.ticketID]?.permit = holds[hold.permit.id]?.permit
            revision += 1
            var result = reply(tickets[hold.ticketID]!); result.disposition = .actionEnded; return result
        case .release(let id, let token):
            guard let hold = owned(id, fence: token, client: client) else {
                if let ticket = tickets.values.first(where: { $0.clientID == client && $0.permit?.id == id && $0.permit?.fence == token && [.released, .revoked].contains($0.disposition) }) { return reply(ticket) }
                return denied(.invalidPermit)
            }
            guard hold.action == nil, hold.fenceReason == nil else { return denied(.resourcesFenced, "A release request is not proof that an in-flight action stopped.") }
            remove(id, disposition: .released, reason: "Permit released at a safe boundary.")
            promote(); return reply(tickets[hold.ticketID]!)
        case .disconnect:
            disconnect(client, reason: "Participant disconnected."); promote()
            return .init(disposition: .disconnected, activity: .unavailable, message: "Participant disconnected; ambiguous actions remain fenced.")
        }
    }

    private func owned(_ id: String, fence: Int, client: String) -> Hold? {
        guard let hold = holds[id], hold.permit.epoch == epoch, hold.permit.clientID == client, hold.permit.fence == fence else { return nil }
        return hold
    }
    private mutating func disconnect(_ client: String, reason: String) {
        clients[client]?.active = false
        for hold in holds.values where hold.permit.clientID == client {
            if hold.action != nil { fence(hold.permit.id, reason: reason + " Confirm its action stopped.") }
            else { remove(hold.permit.id, disposition: .released, reason: reason) }
        }
        for ticket in tickets.values where ticket.clientID == client && ticket.disposition == .queued {
            tickets[ticket.id]?.disposition = .cancelled; tickets[ticket.id]?.reason = reason
        }
        revision += 1
    }
    private mutating func fence(_ id: String, reason: String) {
        guard let hold = holds[id] else { return }
        holds[id]?.fenceReason = reason
        tickets[hold.ticketID]?.disposition = .fenced; tickets[hold.ticketID]?.reason = reason
        revision += 1
    }
    private mutating func remove(_ id: String, disposition: CoordinationDisposition, reason: String) {
        guard let hold = holds.removeValue(forKey: id) else { return }
        tickets[hold.ticketID]?.disposition = disposition; tickets[hold.ticketID]?.reason = reason
        revision += 1
    }
    private mutating func promote() {
        var earlierWaiting: [[CoordinationResource]] = []
        for ticket in tickets.values.filter({ $0.disposition == .queued }).sorted(by: { $0.order < $1.order }) {
            guard clients[ticket.clientID]?.active == true else { continue }
            let blocked = conflicts(ticket.resources, human) ||
                holds.values.contains { conflicts(ticket.resources, $0.permit.resources) } ||
                restartFences.values.contains { conflicts(ticket.resources, $0.resources) } ||
                earlierWaiting.contains { conflicts(ticket.resources, $0) }
            if blocked || holds.count >= 128 { earlierWaiting.append(ticket.resources); continue }
            token += 1
            let permit = CoordinationPermit(id: UUID().uuidString, epoch: epoch, clientID: ticket.clientID, taskID: ticket.taskID,
                fence: token, resources: ticket.resources, grantedAt: now, expiresAt: now + ticket.lease,
                hardDeadline: now + 60, observationAfter: now)
            holds[permit.id] = .init(permit: permit, ticketID: ticket.id)
            tickets[ticket.id]?.permit = permit; tickets[ticket.id]?.disposition = .granted
            tickets[ticket.id]?.reason = "Observe the target, then begin one short action with this permit."
            revision += 1
        }
    }
    private func reply(_ ticket: Ticket) -> CoordinationReply {
        let activity: CoordinationActivity
        switch ticket.disposition {
        case .queued: activity = conflicts(ticket.resources, human) ? .yieldingToHuman : .waitingForAppAccess
        case .fenced: activity = conflicts(ticket.resources, human) ? .yieldingToHuman : .needsAttention
        case .granted: activity = ticket.resources.contains(.foreground) || ticket.resources.contains(.desktop) ? .workingInForeground : .workingInBackground
        default: activity = .idle
        }
        return .init(disposition: ticket.disposition, activity: activity, ticketID: ticket.id,
                     permit: ticket.disposition == .granted ? ticket.permit : nil,
                     message: ticket.reason, retryAfter: ticket.disposition == .queued ? 1 : nil)
    }
    private func normalized(_ resources: [CoordinationResource]) -> [CoordinationResource] {
        var result: [CoordinationResource] = []
        for resource in resources {
            let normalized: CoordinationResource
            if case .window(let application, _, _) = resource, !qualifiedWindowApplications.contains(application) { normalized = .application(application) }
            else { normalized = resource }
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }
    private func conflicts(_ a: [CoordinationResource], _ b: [CoordinationResource]) -> Bool { a.contains { x in b.contains { x.conflicts(with: $0) } } }
    private func validOperation(_ operation: CoordinationOperation) -> Bool {
        switch operation {
        case .reserve(let task, let resources, let lease):
            return valid(task) && !resources.isEmpty && resources.count <= 16 && resources.allSatisfy(\.valid) && validLease(lease) &&
                (!resources.contains(.foreground) || resources.contains(where: {
                    switch $0 { case .application, .window, .browserProfile, .browserSession, .desktop: true; default: false }
                }))
        case .poll(let id), .cancel(let id), .endAction(let id, _): return valid(id)
        case .renew(let id, let fence, let lease): return valid(id) && fence > 0 && validLease(lease)
        case .beginAction(let id, let fence, let observation): return valid(id) && fence > 0 && observation.isFinite
        case .release(let id, let fence): return valid(id) && fence > 0
        case .disconnect: return true
        }
    }
    private func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 180 && !value.contains("\0") }
    private func validLease(_ value: Double) -> Bool { value.isFinite && (1...15).contains(value) }
    private func denied(_ failure: CoordinationFailure, _ message: String? = nil) -> CoordinationReply {
        .init(disposition: .denied, activity: .needsAttention, failure: failure, message: message ?? failure.rawValue)
    }
}
