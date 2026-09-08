# Cooperative coordination prototype

Implemented 2026-09-06 as a pure Swift state machine in
`Sources/LonghaulCore/Coordination.swift`. It is independent of power assertions,
job protection, Nodebay, app windows and Computer Use execution. It does not
intercept native Codex tools or establish that a third-party tool obeys a permit.
The qualification and enforcement limits in
[agent-coordination-feasibility.md](agent-coordination-feasibility.md) still apply.

## API contract for the hosting adapter

`CoordinationBroker` is a Codable value type. One owner must serialize mutations.
The adapter supplies monotonic `now` values, authenticates each peer and implements
the execution boundary. These are separate responsibilities from the state machine.

1. Initialize with the default reconciliation fence. Only a known clean, isolated
   fixture should use `initiallyFenced: false`. If restoring saved broker state,
   call `restart(now:)` before serving any requests. A corrupt or unavailable saved
   state must fall back to the default desktop fence, not an empty, open broker.
2. Call `register(principal:incarnation:now:)`. The principal must be a host-issued,
   authenticated per-participant connection identity bound to the actual peer.
   An agent name or task ID supplied in JSON is not an authenticated principal.
   Different participating sessions in the same process need separate validated
   connection identities. A new incarnation of the same principal retires the old
   client and fences any action whose completion is unknown.
3. Pass a `CoordinationEnvelope` to
   `exchange(_:authenticatedPrincipal:now:)`. Version 1 carries a request UUID,
   the returned client handle (including epoch/incarnation), increasing sequence
   and a typed `CoordinationOperation`.
4. Only a successful **`actionBegan`** reply authorizes the participating executor
   to perform that one bounded action. It must execute each action ID at most once,
   revalidate at the actual execution boundary, then report `endAction`. A granted
   reservation, cached permit, duplicate reply or detected running task is not an
   execution authorization.
5. Report an unknown/cancelled-but-unconfirmed execution result as `indeterminate`.
   Do not release its resources merely because a timer expired. `release` refuses
   in-flight or fenced actions.

The operation cases are:

| Operation | Result and ownership |
| --- | --- |
| `reserve(taskID:resources:leaseSeconds:)` | Atomic grant or FIFO queue ticket; never partial acquisition. Task IDs should be opaque, not prompts or document content. |
| `poll(ticketID:)` | Current owned ticket; polling a live queued ticket renews its queue lease. |
| `cancel(ticketID:)` | Cancels an owned queued ticket. A granted permit requires safe release. |
| `renew(permitID:fence:leaseSeconds:)` | Extends a live owned permit within its hard deadline. |
| `beginAction(permitID:fence:observedAt:)` | Checks current epoch, ownership, fencing token, lease, human priority, no overlapping action and a fresh observation declaration. |
| `endAction(actionID:outcome:)` | `completed` confirms a boundary; `indeterminate` quarantines resources. |
| `release(permitID:fence:)` | Releases an idle permit at a known safe boundary. |
| `disconnect` | Cancels queued work, releases idle holds and fences ambiguous actions. |

Exact duplicate messages return `duplicate` with no permit/action authorization.
Reusing a request UUID with different contents is rejected. Stale sequences,
incarnations and epochs cannot revive permits. An action-start reply lost in transit
must be reconciled, not replayed as another execution. `poll` can recover ticket
state, but never independently authorize an action.

The broker's Codable representation is prototype persistence, not a separately
frozen public wire format. The lead adapter should map its versioned local protocol
explicitly, enforce a 64 KiB frame cap before decoding and paginate/compact trusted
`snapshot()` results before transmitting them. The pure snapshot is not itself a
public unauthenticated status endpoint. No transport is added by this module.

## Resources and concurrency

- `application(bundleID)` is exclusive across the application. A foreground
  action must also name its target app/window/browser resource.
- `window(application:instance:window:)` defaults to the entire app. Only a
  trusted broker configuration in `qualifiedWindowApplications` enables separate
  window reservations. This configuration is evidence from adapter qualification,
  not a permission participants can set for themselves.
- `browserSession(application:profile:session:)` represents an independently
  qualified browser session. Broader `browserProfile` and application reservations
  conflict with the appropriate sessions. An arbitrary tab is not automatically an
  independent session. Native window reservations conservatively conflict with
  browser-session/profile work in the same application.
- `foreground` serializes shared pointer/keyboard use, `clipboard` serializes
  declared clipboard access, and `desktop` conservatively conflicts with every
  modeled UI resource. The executor must honestly identify every shared resource.
- Different background apps or qualified sessions can work concurrently. An older
  conflicting queued request has priority; a blocked queue head does not stop a
  genuinely independent resource. Cancelling or expiring a queued request lets
  later eligible work proceed.

An observation declaration must be at or after the permit's `observationAfter`
and not in the future. This boundary advances after each confirmed action, and a
new grant after waiting or human takeover has a fresh boundary. The core cannot
prove that a timestamp corresponds to a current screenshot or accessibility tree.
An execution-owning adapter must make that observation itself and discard stale
handles/indices after waiting, relaunch or takeover.

## Human priority, expiry and recovery

`setHumanPriority(_:now:)` is a **trusted host/user control**, not a participant
operation. It prevents affected new grants and revokes unused permits. An affected
in-flight action becomes `yieldingToHuman` and remains fenced until it confirms
completion or the host establishes safe release. Clearing human priority never
revives a revoked permit or proves an old action stopped. The broker does not
restore focus, select a Space, type or click.

Default permit lease is 15 seconds. Renewals are bounded to 1–15 seconds with a
60-second absolute maximum per permit, after which a new safe boundary and permit
are required. A participating executor should renew roughly every five seconds.
Queued tickets expire after 30 seconds without participant polling; inactive
clients without queued or in-flight work expire after 60 seconds. UI status reads
must not silently heartbeat an abandoned participant's queue.

An expired **idle** permit can be safely reassigned under the cooperative contract
because an old executor must revalidate before starting anything. An expired
**in-flight** permit remains fenced indefinitely. A timeout is not proof of
cancellation. An active authenticated owner can still report confirmed action
completion after expiry. After disconnect/incarnation change, resolution belongs
to the trusted host.

`confirmSafeRelease(fenceID:evidence:now:)` is also **trusted host only**. The host
must obtain real evidence that the executor stopped, the action completed, or the
user confirmed the resource is safe. The enum is an audit reason, not proof by
itself. Never expose this method as an unrestricted client operation or treat a
client-supplied empty process list as confirmation.

Restart rotates the broker epoch and fences every prior held resource before any
new client can acquire it. Existing user priority is preserved. A reboot can reset
the supplied monotonic clock without reviving old permits. If many unresolved
restarts accumulate more than 256 restart fences, they collapse to one conservative
desktop fence rather than growing without bound or dropping protection.

Other bounds: 16 resources/request; 180 UTF-8 bytes/resource identifier, task ID,
principal and incarnation; 8 open requests/client; 128 queued tickets and held
permits each; 128 retained client records; 512 ticket records before terminal
history compaction; 1,024 handled request IDs. These are prototype limits, not
measured workload capacity claims.

## Verification and remaining gates

On 2026-09-06, standalone Swift 6 typechecking passed and all **22** deterministic
coordination tests passed. The final targeted SwiftPM run completed successfully
in an isolated scratch directory. No tests changed system power settings or drove
native applications. Unit-test evidence does not establish host enforcement.

Run the deterministic fake-clock suite without UI or power changes:

```sh
swift test --filter CoordinationTests
```

Tests represent independent participating clients and cover background concurrency,
app/window/browser conflicts, FIFO and atomic acquisition, clipboard/foreground
serialization, human takeover, abandoned queues, lease/hard deadline expiry,
indeterminate actions, disconnect/new incarnation, persisted restart/reboot,
stale/forged messages, replay, observation boundaries and bounded inputs.

No foreground GUI tests, live human-input detection, hook interception, VM tests,
native Codex/CUA enforcement or actual process-death verification were performed
by these tests. The core cannot prevent an agent from bypassing it. An owned
executor or qualified supported host integration must enforce the permit at its
own action boundary. The lead owns any CLI/IPC adapter and subsequent supervised
two-agent/native-app acceptance. Coordination tickets alone create no power hold
and do not cancel independent render or agent compute jobs.
