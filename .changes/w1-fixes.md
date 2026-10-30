# w1-fixes — bugs found in live testing on 23.05.6

## Backups / rollback with a symlinked config.json (P0)

`/etc/xray/config.json` may be a symlink (that is how the xray package and
`set-cfg` leave it on some boxes). Every snapshot the write pipeline takes used
`cp -a`, which copies the LINK: the "backup" was a second name for the live
file, so the moment the new config was installed the backup held the NEW
content. Rollback (and Backups > Restore) then restored nothing - the broken
config stayed live. Snapshots are now taken with `cp -pL` (dereference, keep
the mode), and the rollback path goes through the same symlink-aware atomic
install the write path uses (`install_config`), so a restore also keeps the
symlink instead of replacing it with a regular file.

## Update button dead on routers whose busybox has no setsid (P0)

The "update now" button detached the self-update with `setsid`, which this
23.05 busybox build does not ship - the command failed with "setsid: not found"
and nothing was updated. It now uses the same detach pattern as the tmpxray
watchdog (background shell that ignores SIGHUP). The detached update also drops
`XRAYMON_NOWAIT`, which the UI backend exports for its own calls: the package's
post-install hooks (`cron-sync`, `enable-api`) take the same lock and would
otherwise fail fast whenever a scheduled fetch happened to hold it.

## Two writers could hold the mutation lock at once (P1)

The old lock recovery ("holder was killed, its PID file is stale, break the
lock") had a race: when two waiters entered it together, the second could
delete the first's fresh owner file and unlock its live lock, leaving two
writers running at once. Locking now uses a kernel flock on an open file
descriptor (busybox `flock`), which the kernel releases by itself the moment
the holder dies - even on SIGKILL. No owner file, no recovery path, no race.
The tmpxray mini-lock uses the same mechanism. The tmpxray instance and its
TTL watchdog now close those descriptors when they start, so a background
child can never keep the lock hostage.

## tmpxray stop / TTL expiry could kill an unrelated process (P1)

`tmpxray stop` and the TTL watchdog killed whatever PID was recorded, trusting
that PID to still be theirs. If the temp xray had already exited and the PID
was reused, the kill hit an innocent process. Both now first check that the
target's `/proc/<pid>/cmdline` still names this instance's temp directory; if
it does not, the kill is skipped and only the state is cleaned up.

## Other

- A stale comment claimed prune keeps 3 backups; the actual default comes from
  UCI `backup_keep` (5).
- The pipeline scenario test now sandboxes the tmpxray lock and state paths as
  well (a run no longer touches the real `/var/lock` or `/tmp/xray-monitor`),
  and it covers the symlinked-config case and the lock itself.
