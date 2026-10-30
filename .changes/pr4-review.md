# pr4-review: fixes for the validated review findings (PR #4)

Six findings fixed on top of integration; the behavior contracts in
CONTRACTS.md Part A are preserved except where noted below.

## Overlapping subscription prefixes could produce duplicate tags

- render.uc: new `owner_prefix(tag, prefixes)` - a tag belongs to the
  longest prefix that equals it or is its `P-` parent; `split_outbounds`
  groups outbounds by that owner, so `proxy-work-fi` lands under
  `proxy-work`, never under `proxy`.
- snapshot.uc now takes `<config> <prefix> [other prefixes...]` and keeps
  only the exits the named prefix owns; xray-sub passes every subscription
  prefix on each snapshot call.
- diff.uc treats a tag as managed iff some prefix owns it (an empty prefix
  list keeps the legacy "everything is managed" behavior).
- apply.uc refuses a staged set that would emit one tag twice, naming the
  tag in the error.
- xray-sub sub-add/sub-edit reject a prefix that equals or nests with an
  existing one ("prefix overlaps with prefix '<P>'").

## Backup was taken before the candidate was validated

`test_and_install` split into `test_config` + `install_config` (the wrapper
stays, for the planned commit_config consolidation). The old config is
backed up only after `xray -test` accepts the candidate; a failed save no
longer creates or evicts backups.

## A killed run left the lock held forever

The flock lives in the lock(1) child, so SIGKILL/OOM bypasses the EXIT
trap. xray-sub now records its PID in `$LOCK.owner` on acquire; a waiter
that cannot take the lock checks the recorded PID with `kill -0`, releases
the orphaned flock (`lock -u`), drops the stale owner file and retries -
within the same 55 s budget. INT/TERM/HUP exit through the trap; the owner
file is removed on release.

## The lock holder inherited stdout

Every `lock` / `lock -u` in xray-sub runs `</dev/null >/dev/null 2>&1`, so
an orphaned holder can no longer keep an rpcd `$(xray-sub ...)` capture
pipe open after the parent is killed (the pre-fix hang).

## rpcd waited out the whole lock poll inside the ubus call

The rpcd backend exports `XRAYMON_NOWAIT=1`: xray-sub tries the lock once
(stale-lock recovery still applies) and exits 1 with "another xray-monitor
operation is running, try again in a moment". The cron path keeps the
bounded wait. The subscriptions view shows the message through the standard
failure notification, which now also covers rpc-level rejections.

## rpcd robustness / honest statuses

- mktemp failures in get_outbounds, config_test, config_save, routing_set
  and balancers_set now answer `{"ok":0,"msg":"cannot create temp ..."}`
  instead of running on with an empty path.
- install_config resolves a symlinked config.json (`readlink -f`) and swaps
  the target atomically - the symlink survives a save.
- fetch with a failed auto-apply reports status `fetched-apply-failed`
  (exit 1, data staged, Apply stays available) instead of reading as a
  fetch failure; the subscriptions page badges cover merge-failed,
  install-failed, fetched-apply-failed and rolled-back.

## Tests

tests/run.sh gains an overlapping-prefix section (snapshot for each
prefix, diff, apply, routing set, duplicate-tag rejection) with goldens
generated on the target router; all checks pass with the ucode fallback
and with real `xray -test` against the shipped config fixtures.
