# Agent task recipe

Give the following instructions to an AI agent after completing the
[installation prompt](../SETUP-PROMPT.md). Replace the final sentence with the
actual work you want. This recipe creates no scheduled task or background service.

---

Complete my requested work with Longhaul reporting its active lifetime.

1. Verify that `/Applications/Longhaul.app` is installed and running, Automatic
   protection is enabled, and the intended integration is available. Preserve
   existing preferences and other tasks. Do not claim protection merely because
   the app is open or `longhaul status` lists a stale job.
2. For a supported Codex task, use the configured native lifecycle monitoring and
   trusted Longhaul hooks. Check for fresh activity and an active protection state.
   Do not invent hook delivery, enable unsupported-format monitoring or add
   duplicate manual jobs for an already reported task.
3. For other command-line work, launch the real foreground task with
   `/Applications/Longhaul.app/Contents/Resources/bin/longhaul run -- COMMAND ARGS`.
   Substitute the actual executable and arguments as separate arguments. Keep the
   worker attached; do not background/disown it and assume the wrapper follows
   detached descendants. Preserve its stdout, stderr and exit status. An idle
   interactive shell is not an acceptable proxy for active task progress.
4. Save useful output incrementally in the intended project. If a genuine
   Longhaul checkpoint request is delivered, write the requested recovery files
   first. Only acknowledge that exact request after verifying accessible,
   nonempty saved artifacts, using
   `longhaul checkpoint-ack REQUEST_ID --files ABSOLUTE_PATH [ABSOLUTE_PATH ...]`.
   Replace placeholders with the real request ID and actual paths; never fabricate
   an acknowledgement or claim an interrupted computation is resumable without
   testing its source application's restore path.
5. Let normal completion, cancellation or failure reach the reporting adapter.
   Longhaul releases protection after the last eligible job and completion grace;
   another live job or manual session may correctly keep it active. Do not disable
   protection globally or kill Longhaul/helpers to finish your own task. If a
   report is stale or missing, state that coverage is unconfirmed.
6. Keep the lid open unless the user has enabled and accepted the experimental
   closed-lid feature. Respect their selected battery cutoff, OS safeguards and
   manual pause. Do not change global sleep settings, defeat lock-screen security,
   or claim that background compute implies locked-desktop Computer Use access.
7. Report the actual deliverables, validation and recovery files. Distinguish task
   completion from Longhaul's protection state and from physical lid/battery
   qualification. Preserve unrelated tasks and saved work.

My task: [Describe the actual work and its output location.]
