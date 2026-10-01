# Current validation serialization

Timing-sensitive compiler/BEAM/socket/browser workflows share one slot across
the coordinator and implementation workers. Source inspection and unrelated
source edits may continue; no worker may infer permission from an old grant.

The current coordinator's ignored runtime lock is:

```text
build/closure/validation.lock
```

Workers use the absolute path of that directory in the coordinator worktree,
not a separate relative lock in their isolated checkout. The parent explicitly
authorizes this temporary coordination directory only.

## Run protocol

1. Obtain an explicit bounded slot.
2. Atomically create the directory. If it exists, fail before launching any
   workload; never delete another owner's lock.
3. Use direct tool calls, unique no-clobber logs and an exact input receipt for
   copied dependency-closure/composed snapshots.
4. Record setup/compile failures separately from assertion failures. Do not
   overwrite the initial failure with a later passing run.
5. Remove the lock in guaranteed cleanup only if this run created it.
6. Release the slot after all child processes have exited and fixture cleanup
   completed. A final worker message must mean no deferred validation remains.

The lock is not containment or provider authorization. It only prevents
accidental simultaneous local validation. Existing unit tests, source workflows,
shipment workflows, native execution and live acceptance remain distinct gates.

## Why this is explicit

Earlier tool dispatches contained duplicate command invocations. Per-worker
locks prevented local duplicates but not coordinator/worker overlap. One F44
completion notification also preceded its renewed execution receipt, allowing
the parent to assume the slot had been released prematurely.

Those histories remain documented, and their timing exclusivity is not claimed.
The shared lock subsequently refused a duplicate parent strict-Codex regression
command before any workload launched; that refusal is not a second test result.
