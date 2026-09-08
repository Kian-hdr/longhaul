# Security and support

Report ordinary bugs with a minimal reproduction through
[GitHub Issues](https://github.com/Kian-hdr/longhaul/issues). Remove private task
names, paths, transcripts and credentials from attachments.

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/Kian-hdr/longhaul/security/advisories/new).
Private vulnerability reporting is enabled. Include affected version, reproduction
steps and impact, with sensitive data removed. Do not disclose vulnerability details
in a public issue. No response-time guarantee is offered.

## Boundaries

The ordinary power assertion belongs to Longhaul's process and has a finite OS
timeout. Optional closed-lid protection uses monitored shared runtime state and
has different failure limits, documented in [qualification](docs/lid-qualification-probe.md).
There is no kernel-owned lease for that shared state. Longhaul does not use the
persistent SleepDisabled override or change lock-screen security.

Job reports use identity, sequence, terminal-state and lease checks. The local
mailbox is not a hostile-process sandbox: code running as the same user can access
user-owned files. Checkpoint acknowledgements are evidence of reported files,
not proof that an arbitrary application can restore a computation.

The optional per-user XPC companion validates UID, app/helper identity and
compatible Developer ID signatures. Its bounded, versioned protocol exposes no
network listener or arbitrary shell endpoint. The relay owns no power assertion.
A fork must deliberately update and sign compatible peers; do not weaken the
identity requirements to make an ad-hoc companion connect.

Codex hooks need exact-definition host trust. Native monitoring checks executable
and writer identity but only supports qualified lifecycle formats. The app does
not collect credentials or bypass Codex trust. See [PRIVACY.md](PRIVACY.md).

## Updates

Download only the official versioned release and verify its checksum, Developer
ID signature and Gatekeeper acceptance. Do not remove quarantine or disable
security checks to open a rejected build. Preserve the previous app and release
owned holds before a controlled update. See [installation](docs/installation.md).
