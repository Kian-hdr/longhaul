# Optional Nodebay connection, protocol 1

Longhaul owns policy, power assertions and recovery. Nodebay is an optional control
surface and job reporter. Either app works independently. Installation detection
alone does not establish a working connection. See [current evidence](STATUS.md).

Longhaul registers a local Service Management agent with an NSXPC Mach service.
Nodebay connects through its existing sandbox helper. The relay checks effective
user ID and Developer ID identity, with distinct host/client roles and a connection
code-signing requirement. Requests and responses are capped at 64 KiB. There is no
TCP listener or arbitrary process execution. The relay owns no power assertion.

The host publishes status and acknowledges queued commands. Client operations are
hello, status, connect, disconnect, pause, resume, keepAwake, job and ackAlert.
Commands carry request IDs and the current server instance. The queue holds at
most 64 commands; status revisions increase monotonically. The host must be fresh
within eight seconds, and peer presence expires after ten seconds. UI controls
use acknowledged state, rather than treating an accepted queue entry as completion.

Nodebay reports explicit job lifecycles through the same policy as other
integrations. Opening an app or using CPU is insufficient. Changing the control
location does not disconnect job reporting, alter automation, or change notice
preferences. Unacknowledged notices retain Longhaul's fallback delivery path.

## Control location

General > Show Longhaul in selects Nodebay or Menu Bar. With no saved choice,
Longhaul prefers Nodebay when installed. A first installation enables the local
connection if available; an explicit prior disconnect is preserved. Service
Management approval requirements remain visible in the app.

The host sends optional snapshot `controlSurface`: `nodebay` or `menuBar`. Omitted
legacy values mean Nodebay. Updated Nodebay clients advertise
`capabilities: ["control-surface-v1"]` in hello/status. The relay exposes optional
`peerCapabilities` only to the host and only while peer presence is fresh. Older
clients remain compatible, but Longhaul keeps its menu-bar control available until
the updated client is connected.

Nodebay persists only routes from accepted snapshots. Invalid or out-of-order
snapshots cannot change the route; unavailability preserves the last accepted
choice. Menu Bar removes the whole notch control allocation. Nodebay Settings
still provides connection and Open Longhaul actions. Longhaul temporarily restores
its menu-bar item whenever preferred Nodebay is missing, disconnected or lacks
support. Its main window remains accessible through Applications or Spotlight.

Focused tests cover legacy decoding, valid/invalid routes, bounded capabilities,
capability expiry, default choice and fallback combinations. Native app switching
and background work require separate installed-app checks recorded in STATUS.
