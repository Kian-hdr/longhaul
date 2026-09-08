# Closed-lid mechanism and alternatives

Longhaul uses ordinary IOKit idle-sleep assertions for normal task protection.
The optional closed-lid mode uses the SDK-defined `kPMSetClamshellSleepState`
selector through `IOPMrootDomain`. This is an experimental low-level integration,
not an Apple promise of an app-scoped lid inhibitor.

Apple's published [user-client source](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/RootDomainUserClient.cpp)
shows a scalar clamshell-state method. It changes shared runtime state rather than
allocating an assertion ID or ownership token. Connection closure does not provide
a per-client balancing release. The published source is evidence about that
revision; it does not certify every installed OS build.

The application supplies short original policy grants to two monitored helpers.
Only app policy evaluations renew a session. Expiry, stale peer contact and unsafe
conditions request cleanup. Durable records distinguish a possible enable,
a clear attempt, accepted cleanup and unresolved cleanup. Helpers cannot create
replacement policy grants. Unknown ownership or cleanup is not fixed by blindly
writing zero or repeatedly fighting system policy.

| Alternative | Boundary |
| --- | --- |
| Ordinary idle assertion | Keeps idle work awake, while lid-close and forced sleep remain separate. |
| Persistent SleepDisabled override | Not used by Longhaul; a global setting is not a scoped task lease. |
| Private lid-aware assertion entitlement | Not used; ordinary third-party eligibility is not established. |
| Powered external-display configuration | A separate system-supported configuration, requiring suitable display/input/power and target-hardware verification. |
| Remote worker | Can continue independently only if the job, tools, files and lifecycle actually run on the remote host. |

The shared method cannot establish exclusive ownership. System services or another
controller may change the same state, and simultaneous helper failure can leave
cleanup unresolved. A software deadline is not a kernel guarantee. No persistent
sleep override, arbitrary privileged shell endpoint or security bypass is shipped.

Manual and emergency sleep preservation has source and simulated evidence; actual
low-battery depletion and thermal emergency testing have not been performed.
See the [bounded physical record](lid-qualification-probe.md). No helper or upstream
implementation code was copied from the researched alternatives; see the
[component inventory](../LICENSE-STATUS.md).
