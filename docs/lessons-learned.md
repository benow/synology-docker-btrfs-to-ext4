# Lessons learned (keep current — every pitfall hit during the real migration)

This file is the accumulation of everything that bit us on a live DS923+ /
DSM 7.2 migration. If you hit something new, add it here.

## Synology portability gotchas

1. **No `mountpoint` binary.** Synology doesn't ship it. `mountpoint -q` in a
   `mounted()` helper silently fails (command-not-found) — worse, inside
   `mounted || { mount ...; }` it makes the mount branch run and fail on an
   already-mounted target under `set -e`. Fix: check `/proc/mounts` directly
   (`grep -qs " ${MNT} ext4 " /proc/mounts`).
2. **`df -Bm` appends an `M` suffix** on Synology (`11802150M`), breaking
   `[ "$free_mb" -gt 368640 ]` with "integer expression expected". Fix:
   pipe through `tr -dc 0-9`. (This bug survived because every test run died
   upstream before reaching the line — surviving-because-unreached bugs are a
   theme; see testing note below.)
3. **`docker system df` is NOT a shortcut** for tree size on a sick
   filesystem. It stats every image layer, container rw layer, and volume —
   the same metadata walk `du` does. On the btrfs sandwich both take many
   minutes. The size pre-check is advisory anyway (the copy is
   checksum-verified and resumable), hence `SKIP_SIZE_CHECK=1`.
4. **`docker` is not on the non-interactive ssh PATH.** Every remote
   invocation needs `export PATH=/usr/local/bin:$PATH`.

## rsync / data-root realities

5. **Unix sockets in stopped containers' layers cannot be rsync'd** — rsync
   tries `mknod` and fails ("File name too long" for the socket-path names it
   mangles; ENOENT/EPERM variants elsewhere). They are dead IPC handles
   (dotnet diagnostic sockets, Chromium `SingletonSocket`/`SingletonCookie`).
   Fix: exclude `*.socket` and `Singleton*` from BOTH the transfer and the
   verification pass, or the transfer exits 23 and verification false-fails.
6. **`--info=progress2` can read >100%** (we saw 198%). The percentage's
   denominator shifts as rsync discovers files. Trust the byte counter and
   the destination fill level, not the percentage.
7. **Prune BEFORE you copy.** Junk (stale CI-tagged images, dangling layers,
   BuildKit cache) deleted while dockerd is up is data rsync never moves —
   and with `--delete`, a re-run removes already-copied junk from the
   destination too. Do not copy a 200 GB tree when 80 GB of it is garbage.
8. **The tree is bigger than you think.** "Docker, ~50 GB" was ~220 GB:
   months of CI-deployed image tags (never pruned), postgres volumes with
   real data, container rw layers, and the embedded BuildKit cache. Size the
   image generously (300G minimum for a busy host) and know `grow` exists
   (truncate + online `resize2fs`, safe while mounted).
9. **`SKIP_SIZE_CHECK` is safe because verification is the real gate**: rsync
   fails safely on a too-small image (original never written), and `copy`
   re-runs.

## Design choices that paid off

10. **Staged + state-file + idempotent.** Every stage gates on a state file
    and re-runs cleanly. We resumed after: a hung du, two reboots, a DSM +
    ContainerManager update, and the socket discovery — none required
    starting over.
11. **`chattr +C` on the image file BEFORE data exists** (sparse truncate →
    chattr → mkfs). Setting it after data is written does nothing for
    existing extents; the outer btrfs would CoW the loop file anyway.
12. **Automatic rollback at cutover with FOUR checks** (dockerd answers, root
    took effect, ≥5 containers visible, frontend 200). Each check exists
    because a silent partial success is the dangerous outcome.
13. **Verbose-by-flag tracing (`VERBOSE=1`)** was added mid-migration because
    a silent `du` looked like a hang. Long stages must narrate themselves.

## Process / testing

14. **Exercise every line before the maintenance window.** The `df` suffix
    bug and the `mountpoint` bug were both latent for months because earlier
    runs never reached them. When you patch a script mid-flight, re-run the
    earliest stages too — not just the stage you think you fixed.
15. **Never hand-`rm` inside the OLD data-root** to speed things up — only
    docker-driven pruning is safe there. Hand deletion corrupts images and
    container layers.
16. **A reboot mid-migration is survivable but expensive**: ContainerManager
    can sit in `activating` for up to 10 minutes post-boot while its startup
    check waits for dockerd on the sick volume. Patience beats intervention;
    the containers keep running under containerd meanwhile.
17. **Recycle bins hide terabytes.** DSM's per-share `#recycle` never
    auto-empties by default; a "deleted" 1 TB VM image from 3 years ago was
    still there. Emptying reclaimed 7 TB (83% → 57% fill) and moved the
    volume out of btrfs metadata-ENOSPC territory. Enable per-share auto-clean.

## Roadmap lessons (guard + pruning — see docs/boot-guard.md)

18. **ContainerManager package updates can regenerate `dockerd.json`** and
    silently revert the data-root. The failure mode is not data loss but
    STATE DIVERGENCE: dockerd runs on the stale tree, new work lands there,
    and switching back makes that day's work "vanish". Auto-repair on boot;
    hard-fail the docker start chain when repair is impossible.
19. **After `retire-old`, set the old subvolume read-only**
    (`btrfs property set <path> ro true`) — a landmine that makes any
    accidental use of the old root fail on first write instead of silently
    forking state.
20. **Prune at deploy time, not migration time**: a post-deploy step keeping
    the last N image tags per repository (default 2) prevents the
    accumulation from ever rebuilding. Registry-side GC is a separate,
    more invasive task (needs read-only mode + garbage-collect).

## Testing note (the meta-lesson)

Bugs #2 and #1 both survived because tests stopped at the first failure.
When validating a staged script, run every stage end-to-end in a sandbox (or
at least `bash -n` + command-inventory check against the TARGET system —
`mountpoint`, `df` behavior, `docker` PATH) — not just the path you expect
to execute. Commands referenced in error messages must be verified to exist.
