# Sizing, memory, and build performance

## Image sizing

- Default `IMG_SIZE=300G`. The preflight check (skippable) warns if the
  Docker tree exceeds 80% of it.
- A "50 GB" Docker tree turned out to be ~220 GB on a busy CI host. Budget
  generously: **images dominate** — every CI deploy tags new images, and
  unpruned they accumulate for months.
- The image is **sparse + `chattr +C`**: it consumes only what rsync puts in
  it, and the outer btrfs does no data CoW on it.
- If it ever fills: `grow 400G` extends the sparse file and online-resizes
  the ext4 **while mounted and docker running** — a two-minute fix, not a
  crisis. Keep 20%+ free inside the image for BuildKit's working space.

## Pruning strategy (the real space lever)

Junk lives in the data-root in three forms:

| Junk | Cause | Fix | Safe? |
|---|---|---|---|
| Stale CI image tags (`:<arch>-<sha>`) | every deploy pushes a new tag | keep 2 newest per repo, `docker rmi` the rest | yes — re-pullable from the registry |
| Dangling layers | retagged/rebuilt images | `docker image prune -f` | yes |
| BuildKit build cache | embedded cache under the data-root | `docker builder prune -f` | yes but forces rebuilds — flag-gated |
| Container rw-layer /tmp junk | sockets, Chromium temp dirs | sockets excluded from migration; live cleanup via container restart | n/a |

**Prune at deploy time, not crisis time**: a post-deploy step running the
keep-N prune on the target host means each deploy self-cleans and the
accumulation never rebuilds. Weekly backstop run for hosts that missed
deploys. (Registry-side GC on registry.benow.ca is separate and more
invasive — needs read-only mode + `registry garbage-collect`.)

**Never** `docker system prune --volumes` on a host with named volumes
holding real data (databases, plugin storage). Never hand-`rm` inside the
data-root.

## Host memory considerations (DS923+, 8 GB example)

- Docker + DSM + a QEMU VM (2 GB `-mem-prealloc`) + two CI runner containers
  is a tight fit: observe ~500 MB free with 5 GB in page cache under load.
- **`-mem-prealloc` trades host flexibility for guest latency** — right call
  when the host has memory to spare, wrong on an 8 GB box. Alternatives:
  shut the VM down when unused (best), or drop prealloc so it uses only what
  it touches.
- **RAM upgrade is the single best hardware spend** once storage is fixed.
  DS923+: 2 SODIMM slots, DDR4 ECC unbuffered 2666, official max 32 GB
  (2×16 GB; 64 GB works unofficially). Non-ECC modules work — Synology's own
  stock modules report ECC: None. Third-party DDR4-3200 SODIMMs downclock to
  2666 harmlessly; expect a "non-Synology memory" notice and a boot-time
  memory test.
- On a storage-bottlenecked box, **RAM is a performance lever, not just
  headroom**: page cache absorbs the small-write storms that the (now-fixed)
  btrfs sandwich used to amplify. With 32 GB, cache + runners + VM coexist
  without thrashing.

## Build performance stack (ordered by impact)

1. **This migration** — non-CoW graphdriver storage. Fixes the ~10×
   small-write penalty in `docker build` (dpkg/apt/restore steps).
2. **BuildKit content-addressed caching** — `DOCKER_BUILDKIT=1` with the
   docker driver validates COPY layers by content, not mtime; fresh
   checkouts stop invalidating restore layers. Note: the docker driver can't
   export cache (no registry/local/inline export) — the persistent local
   cache under the data-root IS the cache.
3. **Push the fat restore stage as an image** (`nastv-base:restore-<arch>`)
   to your registry — cold-start/other-host insurance.
4. **Keep SDK/Gradle caches in a durable bind mount** (survives runner
   container recreation), not in image layers.
5. **Don't add NuGet cache-mounts to a restore stage that a later
   `--no-restore` publish depends on** — cache-mount content isn't part of
   the image layer; the publish loses the packages.
6. **Enough RAM** that parallel build legs don't evict the page cache
   mid-build.

## Measuring improvements

```bash
time docker system df                 # minutes → seconds
time du -sm <data-root>               # hours → minutes
# re-run a representative build; compare the dpkg/restore step
```
