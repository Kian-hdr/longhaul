# Closed-lid design boundary

Longhaul's ordinary `PreventUserIdleSystemSleep` assertion protects idle work;
it does not prevent lid-close sleep. The optional closed-lid implementation uses
a separate, experimental shared runtime mechanism. Its current qualification is
recorded in [lid-qualification-probe.md](lid-qualification-probe.md).

Longhaul does not use the persistent `pmset disablesleep` / `SleepDisabled`
override. It keeps ordinary manual and OS emergency sleep handling in its design.
The shared clamshell mechanism is not a kernel-owned process lease, and successful
API calls alone do not establish continuing protection or cleanup.

See [mechanism and alternatives](closed-lid-alternatives.md) for the technical
contract and source pointers. An OS update, a different Mac or battery operation
requires separate qualification. Keeping a Mac awake does not unlock its session
or make a locked desktop available to an agent.
