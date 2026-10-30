# F-prep — write-pipeline extension points

## What changed

No user-visible behavior change: every config write (`apply`, `routing-set`,
`balancers-set`, `config-save`, `enable-api`) takes the same backups, in the
same order, with the same messages and exit codes as before. Internally the
five hand-copied sequences in `xray-sub` were consolidated into one function:

- `commit_config <kind> <need_api> <candidate> [no-restart]` — `xray -test` the
  candidate, snapshot the live config (`$CFG.bak[.<kind>].<timestamp>`), install
  it atomically (symlink-aware), restart xray, `verify_or_rollback` (restores the
  snapshot if xray or the stats API does not come back), then the new hook
  point, then `prune_backups`. Returns 0 = installed and healthy, 1 = the
  candidate failed `xray -test` (config untouched, no backup taken), 2 =
  installed but rolled back, 3 = the install step failed; backup pruning or a
  hook failing can never turn a successful write into a failure. The last
  snapshot lands in `$COMMIT_BAK` for the caller.
  Ordering note: for `apply`/`routing-set`/`balancers-set` the backup is now
  taken after the `.uc` transform instead of before it — content-equivalent,
  since the transform only reads the live config; the only difference is that
  a crashed transform no longer leaves a backup file behind.
- `post_restart_hooks` — empty function, run under the write lock after every
  successful restart+verify, before old backups are pruned. Placeholder for
  follow-up features (F15).
- `no-restart` mode — validate, then snapshot, then atomic replace: no restart,
  no verify, no hooks, no prune. A candidate that fails `xray -test` leaves
  nothing behind (no snapshot is taken until the candidate validates, and
  `$COMMIT_BAK` stays empty). For the upcoming hot-swap flow (F14), which
  reconciles the running xray via `xray api` and falls back to a full restart
  + `verify_or_rollback "$COMMIT_BAK"` if that fails.

## How to verify

- `sh tests/run.sh` and `XRAY=/usr/bin/xray sh tests/run.sh` still pass
  (the golden suite is unchanged — the pipeline is shell-side only).
- New: `sh tests/pipeline-scenario.sh` (router or any host with ucode +
  ucode-mod-fs) runs every write path inside a sandbox with stubbed
  xray/pgrep/uci/init.d and asserts: backup kind and content, candidate
  tested then installed, restart invoked, hooks fired, prune run, the
  test-failed and rolled-back paths, that `no-restart` installs without
  restarting (and leaves nothing behind on a rejected candidate), and that a
  failing backup prune cannot fail the write. `KEEP_SB=1` keeps the sandbox
  for inspection. Nothing outside the sandbox is touched.
- Manual: change routing or balancers in the UI (or `xray-sub routing-set`),
  confirm `ls -t /etc/xray/config.json.bak.*` still shows the same backup
  names as before and that xray restarts exactly once per change.
