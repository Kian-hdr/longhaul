# Privacy

Longhaul processes job state locally. It has no analytics, account, cloud service,
telemetry upload or public network listener. The current app uses native IOKit
power information and an authenticated, per-user XPC connection for optional
Nodebay integration.

The local data directory contains lifecycle events, job titles, process identity,
progress, checkpoint paths, recovery acknowledgements and a diagnostic history.
It does not intentionally retain prompts, transcripts, screenshots, clipboard
content, API credentials, raw tool input or command arguments. Codex passes hook
payloads to the command helper; that helper extracts bounded lifecycle fields and
does not persist the rest. It may return a checkpoint instruction to the agent.

Native Codex activity monitoring also inspects process and writable-file metadata
and reads bounded portions of local session logs to extract lifecycle events.
Only native host/process identity, task and turn identifiers, supported format
version, lifecycle timestamps and phase are retained in memory. Log bytes and
conversation fields are discarded; transcripts are not copied into Longhaul's
mailbox, history or diagnostic export. This monitor can be turned off separately
in Integrations. Unsupported formats and unverifiable writer identity are reported
as unavailable rather than assumed active.

Blender scene copies and Resolve project exports can contain sensitive project
data and references. They stay on the user's Mac. Saved copies are not uploaded
or automatically deleted. Review exported diagnostic history before sharing it;
job titles and paths can identify personal work.

Runtime metadata uses a private application-support directory (0700) and files
readable only by the current user (0600). It remains accessible to background
workers when the screen locks; Longhaul does not apply a lock-dependent file
protection class to those records. System security settings remain unchanged. This is not
an encrypted backup and does not prevent another process running as the same user
from reading user-accessible files. The Nodebay XPC endpoint additionally validates
UID, exact app/helper identifiers and compatible Developer ID signatures. The
mailbox accepts cooperating local producers; it is not a hostile-process sandbox.

Optional notifications and login launch are requested through macOS. Longhaul does
not request Accessibility or Screen Recording, change lock-screen settings, weaken
Gatekeeper or unlock the desktop. Agent Computer Use permissions remain with the
agent's own host.
