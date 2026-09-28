---
name: land
description: >-
  Land an explicitly requested MIMIC change into the primary local repository's
  main branch using the existing jujutsu-workflow skill. Invoke only when the
  user requests landing or merging, including Land Changes or /land; do not
  invoke for review, preparation, passing checks, or installing this skill.
disable-model-invocation: true
metadata:
  delta-action: land
---

# Land MIMIC locally

This is a project-specific adapter to the existing global `jujutsu-workflow`,
not a replacement for it. It adds MIMIC verification, local destination
integration, and verified landing reports. Do not modify or rename the global
skill.

An explicit Land Changes or `/land` invocation supplies landing intent.
Proceed through this workflow without asking for merge permission again.
Stop only for a real blocker, unresolved scope, or a separate permission
boundary described below. Approval to install this skill is not a landing
request.

## Reuse the authoritative workflow

Load `jujutsu-workflow` with the skill tool. Delegate repository-mode detection,
change preparation and descriptions, non-interactive Jujutsu operation,
bookmark handling, conflict inspection, operation-log recovery, and final
Jujutsu/Git state inspection to it and its referenced guides:

- `~/.agents/skills/jujutsu-workflow/SKILL.md`
- Its `references/git-interop.md`, `references/agent-safety.md`,
  `references/parallel-agents.md`, and `references/recovery-playbook.md`.

If it is unavailable, stop and report the dependency; do not silently replace
it with raw Git mutations. Apply the project-specific additions below rather
than copying the generic PR handoff procedure into a local landing.

The existing workflow's PR handoff script is not evidence that a change has
landed locally. Use its documented final state-inspection alternative for this
local workflow. Do not weaken its protected-branch checks or call a prepared
topic bookmark a completed landing.

## Scope and destination

Read current applicable instructions and policies before execution. In
particular, `AGENTS.md:7-18` requires Gleam domain logic, secret-safe local
tests, `apply_patch` for source edits, Jujutsu rather than mutating Git, and no
commits during parallel work. `AGENTS.md:28-48` establishes ownership boundaries
and excludes real secrets and runtime data from source artifacts.

At setup, the attached source was a managed Delta checkout and its only Git
remote, `local`, identified `/Users/jerryjohnson/dev/mimic/.git`. The primary
checkout was `/Users/jerryjohnson/dev/mimic`, with an unborn `main`; there was
no source-hosting remote or established commit history. These are observations,
not permanent assumptions. Resolve and recheck the actual source and primary
destination every time. Never choose an arbitrary sibling checkout.

This skill lands into **local `main` in the verified primary MIMIC repository**.
It does not publish code to a hosting service, push through the `local`
backlink, or push a default branch. If the repository's actual target or
contribution policy has changed to require another workflow, stop and explain
the mismatch instead of bypassing it.

Before modifying a primary checkout outside this thread's attached worktrees,
ask the user to attach it. Direct edits there are allowed only if the user
explicitly chooses that alternative. This is a workspace permission boundary,
not a second request for merge intent. Until resolved, report that landing is
blocked and do not mutate that checkout.

Establish that parallel writers have finished or paused before preparing
commits. Do not infer their completion from an old transcript. Inspect the
actual source/destination state and any current coordination information;
ask when writer ownership remains unresolved.

At setup, no contribution template, signing requirement, CLA/DCO requirement,
human-authored submission requirement, or mandatory PR policy was present.
Recheck applicable policies at execution; apply any newly applicable unmet
requirements without inventing obligations or re-asking already settled ones.
Do not change user identity, signing configuration, branch protection, or
global tool configuration merely to make a landing succeed.

## Preserve scope and unrelated work

Establish the intended change set, source revision, destination revision, and
operation-log recovery points before mutations. Review the complete candidate
diff and exclude secrets, runtime state, build outputs, and unrelated files.
If the candidate includes work whose ownership is unclear, stop for scope
clarification rather than bundling it.

The primary checkout had seven existing documentation files matching the
source exactly and an unrelated untracked `erl_crash.dump` at setup. Recheck
these facts; do not open, delete, publish, or accidentally snapshot the dump.
Never discard unrelated tracked or untracked destination work to get a clean
status.

Disable automatic tracking of new files for Jujutsu operations used by this
landing, using the per-command option
`--config 'snapshot.auto-track="none()"'`. Explicitly track only reviewed,
intended new paths with `jj file track <paths>`; do not use `--include-ignored`
or broad all-file tracking. Existing tracked edits still need scope review.
This prevents incidental destination files from entering a working-copy
commit during preparation. Do not change the user's global auto-track setting.

Use the upstream workflow for preparing the approved source change and a
uniquely named temporary topic bookmark. All interactive/editor forms remain
prohibited. The initial repository may legitimately require an initial commit
containing the assembled application and approved repository configuration;
do not assume an existing parent commit or a PR can be created.

## Required verification

Use the current manifests and task definitions, not old test counts or a
previous worker's success report:

- `gleam.toml:5-6` selects Erlang and requires Gleam >=1.18.0.
- `.github/workflows/ci.yml:12-20` specifies Gleam 1.18.1, OTP 28, Rebar3,
  BLAKE3's `b3sum`, zstd, and OpenSSL for CI.
- `Makefile:5-16` defines the project's test, check, format, and build targets.
- `.github/workflows/ci.yml:21-25` defines the verification commands below.

Locate a working toolchain without installing or reconfiguring global tools
silently. Check versions as well as executable presence. The setup host had
OTP 29, Rebar3, `b3sum`, zstd and OpenSSL; Gleam was not on its default PATH.
Prefer a verified Gleam on PATH, an explicit operator-supplied executable, or
the source checkout's `.tools/gleam`. A compiler in another checkout may be
used only after checking its existence/version; never use that checkout's
source as a substitute for the landing candidate.

If a required tool is missing, stop and request a usable path or environment.
Keep any temporary PATH selection local to the process. Record an OTP version
different from CI's OTP 28 rather than presenting it as the same environment.
If current policy requires an exact environment, satisfy it before proceeding.

Run against the final candidate tree:

```sh
gleam deps download
gleam format --check src test
gleam test
gleam run -- doctor
gleam export erlang-shipment
```

Source for these exact invocations:
`.github/workflows/ci.yml:21-25`; format and test are also defined by
`Makefile:8-10`. `doctor` checks tool availability, not the success of tests or
the Docker daemon. Required corpus/TLS tools must actually be available.

All required checks must finish successfully for the exact code being landed.
Pending, failed, missing, or unverifiable checks block landing. Do not use
`docs/VALIDATION.md` or an earlier 179-test result as the gate for a new tree.
Do not skip the suite for docs-only changes without a current repository
exemption. Do not run live provider calls, real-account OAuth, deployment,
container workloads, or package publication as part of this local landing.

If conflict resolution or any other source/configuration edit changes the
candidate, rerun applicable required checks on the resulting tree. Account for
tracked changes a tool may generate, such as a changed dependency manifest,
before finalizing the candidate revision.

There is no verified hosted CI destination in the setup configuration. Run the
local gate and label it local; do not claim remote CI passed. If applicable
repository policy or verified destination settings now require remote checks,
reviews, or other approvals, all must pass for the exact candidate before
landing. If they cannot be verified, stop rather than substituting local tests.

## Integrate into the actual primary repository

Use the existing Jujutsu workflow for source change/bookmark preparation and
Git interoperability. The additional local integration sequence is:

1. Export the prepared, reviewed topic bookmark to the source clone's Git
   backing store with `jj git export`. Obtain that store's actual absolute path
   with read-only `git rev-parse --absolute-git-dir`.
2. In the permission-approved primary repository, import the candidate from
   that **local source store**, not by pushing `local`. Use a uniquely named
   temporary Jujutsu Git remote, then fetch only the prepared topic branch:

   ```text
   jj git remote add <temporary-source-remote> <absolute-source-git-directory>
   jj git fetch --remote <temporary-source-remote> --branch <topic-bookmark>
   ```

   These are Jujutsu 0.43.0 interfaces verified during setup with
   `jj git remote add -h` and `jj git fetch --help`. Apply the non-interactive
   and auto-track options established above. Check name/path collisions;
   never overwrite an existing remote or bookmark belonging to the user.
3. Determine the integration candidate without rewriting existing shared
   history:
   - If `main` is unborn, use the verified initial application commit.
   - If current `main` is an ancestor of the candidate, fast-forward.
   - If histories have legitimately diverged, create a merge change with
     Jujutsu using both revisions as parents and an explicit message. Resolve
     conflicts under the policy below, and verify the actual merged tree.
     Do not use a blind sideways bookmark move as a substitute for merging.
4. Preserve any private destination working-copy changes separately from the
   landing commit. Use the upstream workflow's reversible change/rebase
   facilities only for these unpublished changes. If the working tree cannot
   safely represent the new base without altering unrelated work, pause.
   Resolve and validate this before moving the destination bookmark.
5. Recheck that `main`, the candidate, and the reviewed change scope have not
   changed while verification ran. If they have, recompute integration and
   repeat the affected checks; never land using stale check results.
6. Create unborn `main` with `jj bookmark create main -r <verified-candidate>`
   or advance existing `main` with
   `jj bookmark move main --to <verified-candidate>`, then `jj git export`.
   This is a **local bookmark/ref update**, not a default-branch push.
   The interfaces were verified with `jj bookmark create -h`,
   `jj bookmark move --help`, and `jj git export -h` during setup.
7. Leave the primary working copy usable on the landed base while preserving
   its unrelated work. Follow the existing workflow for the appropriate
   post-landing working change. Do not edit another workspace's active change.

The local transfer commands above are the additional behavior missing from
the generic workflow; its PR creation instructions are not a substitute for
these destination updates. Check installed Jujutsu help if its version differs
from the verified 0.43.0 interface. Do not invoke unsupported wrapper flags.

### Conflict policy: automatic when clear

The user chose automatic resolution of unambiguous conflicts. Resolve those
non-interactively with `apply_patch`, preserving the intended behavior and
unrelated work, then rerun the required checks. Do not stop merely because a
clear conflict exists.

Pause for genuinely ambiguous intent, unsafe resolution, affected unrelated
work, or failed checks. Report the unresolved paths and a specific decision
needed. Never erase a side wholesale, force a bookmark backwards, rewrite
shared history, or force-push to make the conflict disappear.

## Verify the destination and report

Success requires all of the following, not merely a prepared commit:

- The primary repository's Git-visible `refs/heads/main` resolves to the
  intended landed revision after export.
- The requested changes are present in that revision's tree and the primary
  working copy reflects the landed base, with unrelated work preserved.
- The final diff contains only the approved landing scope; required checks
  passed for that exact integrated tree.
- There are no unresolved conflicts or silently abandoned changes.
- The upstream workflow's final Jujutsu/Git state inspection has been performed.

Inspect `git rev-parse refs/heads/main`, the landed revision/tree, and
read-only Git status in the actual destination. A successful status command,
topic-branch export, fetch, or source commit alone is not landing success.

Remove only temporary remotes/bookmarks created by this invocation and only
after the landed commit is reachable from verified destination `main`.
Do not delete workspaces or user files. Retain failed-attempt state needed for
safe recovery. Follow the upstream recovery guidance and disclose any recovery
operation used; never undo another actor's concurrent work.

When running in a subthread with `report_subthread_status`, report:

- `success` only after verifying landing at the intended destination.
- `failure` for an unsuccessful attempt or a genuine blocker, explicitly
  stating that the requested landing is not complete.

Use a short sentence-case title, such as `Landed on local main` or
`Blocked by failed checks`, and a one-line description with the verified short
commit SHA and actual check outcome. Link commit/CI results only when their
URLs exist and were verified; local-only commits and local checks may have no
such URLs. Do not fabricate GitHub links or claim hosted CI success.

Do not send outcome events for installing this skill, ordinary progress,
passing tests alone, or exporting a topic bookmark. Keep questions in the
conversation, not the event. Failure is nonterminal: continue safe permitted
recovery and report the updated outcome after verification.

If the reporting tool is unavailable, report the same verified result directly
in the conversation. Summarize the destination, landed SHA, checks, preserved
unrelated work, and any remaining limits without claiming provider parity or
unperformed external validation.
