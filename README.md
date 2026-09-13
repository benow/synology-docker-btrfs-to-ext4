# synology-docker-btrfs-to-ext4

Resumable, checksum-verified migration of Synology's Docker data-root from a
double-btrfs layout (btrfs graphdriver on a btrfs volume) onto an ext4 loop
volume with the aufs graphdriver — plus pre-copy pruning, a boot-time
regression guard, and space reclamation.

## Who needs this

Synology's ContainerManager on DSM 7 (kernel 4.4.x) runs Docker with the
**btrfs graphdriver on top of a btrfs volume** — CoW on CoW. Every container
layer write pays double copy-on-write, and small-write/fsync-heavy workloads
(package installs in image builds, database writes, metadata walks) run
**~10× slower** than they should. DSM has **no overlayfs** in its 4.4 kernel
but **does have aufs**, so Docker *can* run fast — it just needs a non-CoW
filesystem under it.

This script set moves Docker's data-root onto an **ext4 loop image** (with
`chattr +C` so the outer btrfs does no data CoW on the image file itself).
The inner ext4 becomes the only filesystem doing real work.

## Measured symptoms → improvements

See [docs/symptoms-and-results.md](docs/symptoms-and-results.md) for the
before/after evidence and [docs/lessons-learned.md](docs/lessons-learned.md)
for every pitfall hit along the way (including Synology's missing `mountpoint`
binary, `df -Bm` unit suffixes, and why `docker system df` is not a shortcut
on a sick filesystem).

## Quick start

```bash
# 0. Inspect, read-only. Resolve any warnings before continuing.
sudo env VERBOSE=1 bash scripts/migrate-docker-ext4.sh preflight

# 1. Zero downtime: create the ext4 image, mount it, install the boot mount unit
sudo env VERBOSE=1 bash scripts/migrate-docker-ext4.sh prepare

# 2. Maintenance window starts here (~10-30+ min downtime):
#    prune junk (dockerd up), stop stack + dockerd, rsync, checksum-verify
sudo env VERBOSE=1 bash scripts/migrate-docker-ext4.sh copy

# 3. Point dockerd at the new root and verify — AUTO-ROLLS BACK on any
#    failed check (dockerd up, root took effect, >=5 containers, frontend 200)
sudo env VERBOSE=1 bash scripts/migrate-docker-ext4.sh cutover

# 4. Run for days/weeks to build confidence, then:
sudo bash scripts/migrate-docker-ext4.sh retire-old
```

`migrate` chains all four stages if you prefer one command — each stage gates
on a state file and is idempotent/resumable, so any failure means re-running
`copy` (rsync resumes), never starting over.

## Safety model

- **The original `/volume1/@docker` is never written to** until the explicit,
  final, manual `retire-old` (which renames, not deletes).
- `copy` runs a full **checksum verification pass** (`rsync -c` must produce an
  empty diff) before declaring the trees identical.
- `cutover` **auto-rolls-back** (restores the `dockerd.json` backup, restarts
  dockerd + stack on the original root) if any post-cutover check fails.
- Unix sockets in stopped containers' layers (dotnet diagnostic sockets,
  Chromium singletons) are excluded from both transfer and verification —
  they are dead IPC handles, not data.
- A **boot guard** (see docs/boot-guard.md) repairs `dockerd.json` if a
  ContainerManager package update silently reverts the data-root — and fails
  the docker start chain loudly if it can't.

## Commands

| Command | Purpose |
|---|---|
| `preflight` | Read-only checks: space, aufs, tooling, CI-in-flight warning |
| `prepare` | Create + mount ext4 image, install systemd mount unit (zero downtime) |
| `copy` | Pre-copy prune → stop stack/dockerd → rsync → checksum verify |
| `cutover` | Switch `dockerd.json`, verify, auto-rollback on failure |
| `status` | State, mount, dockerd, data-root, container count |
| `rollback` | Manual cutover rollback (restore config backup, restart on old root) |
| `reclaim` | Prune dangling images + stale CI tags; `--recycle` empties share recycle bins; `--balance` runs incremental btrfs balances |
| `grow <size>` | Enlarge the image + online-resize ext4 while mounted (e.g. `grow 400G`) |
| `retire-old` | Final step: rename the original tree (renames, never deletes) |

Environment flags: `VERBOSE=1` (bash -x trace), `SKIP_SIZE_CHECK=1` (skip the
tree-size measurement — sizing is enforced by copy-stage verification anyway),
`PRUNE=0` (skip pre-copy prune), `PRUNE_BUILD_CACHE=1` (also clear the
BuildKit cache).

## After any NAS reboot or ContainerManager update

Run `status`. A ContainerManager package update can regenerate `dockerd.json`
and silently revert the data-root to the old btrfs tree. The boot guard
repairs this automatically; `status` is the manual check and the README-in-
the-data-root is the breadcrumb for whoever looks next.

## Requirements

- DSM 7 with ContainerManager; kernel 4.4.x **with aufs** (the script asserts
  this in preflight — the whole design depends on it)
- Free space: the 300G image (configurable, `IMG_SIZE`) + 20% headroom
- `rsync`, `mkfs.ext4`, `python3`, `e2fsprogs` (present on DSM 7 by default)
- A maintenance window: the stack is down from mid-`copy` to end of `cutover`
- Verified on: DSM 7.2, DS923+ (AMD Ryzen R1600). Theory works on any
  aufs-capable kernel without overlayfs.

## Documentation

- [docs/symptoms-and-results.md](docs/symptoms-and-results.md) — what's slow,
  how to measure it, what improves
- [docs/lessons-learned.md](docs/lessons-learned.md) — Synology portability
  gotchas and mid-migration surprises
- [docs/boot-guard.md](docs/boot-guard.md) — surviving ContainerManager
  updates that revert `dockerd.json`
- [docs/sizing-and-memory.md](docs/sizing-and-memory.md) — image sizing, host
  RAM considerations, CI runner memory pressure, build-cache trade-offs

## License

MIT
