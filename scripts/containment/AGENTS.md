# F02 tooling ownership

This directory is F02-owned containment tooling, not a provider engine.
Policy, authorization and lifetime decisions remain in `mimic/containment`.
Python here is only synthetic fault/fixture QA. No target execution on the host.
No downloads, image builds or daemon management as part of execution/selftests.
An absent kernel/OS primitive is a blocking prerequisite, never a fallback.

The operator approved a narrow Linux syscall launcher in Zig.
`scripts/containment/launcher/` may implement OS restrictions and `execve`;
scenario authorization, budgets and process-tree lifetime remain Gleam-owned.
Launcher kernel probes are explicit synthetic container tests, never host targets.
