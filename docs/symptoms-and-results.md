# Symptoms and results

## How to tell you have the double-btrfs problem

Run these on your Synology. If the first says `btrfs` and your volume is
btrfs, you have the sandwich.

```bash
docker info | grep -E "Storage Driver|Docker Root Dir"   # Storage Driver: btrfs
df -T /volume1                                            # Type: btrfs
```

## Symptoms we observed (DS923+, 4-core Ryzen R1600, 27T btrfs volume)

| Symptom | Evidence |
|---|---|
| `du` over `/volume1/@docker` takes **hours** for ~100 GB | du is a pure metadata walk; double CoW + ext4-style small metadata ops crawl on btrfs |
| `dpkg`/`apt` inside `docker build` runs **~10× slower** than bare metal | image builds re-ran `dotnet restore` (~9 min) every time despite unchanged lockfiles; small-write/fsync workloads pay double CoW |
| `docker system df` takes **minutes** (it walks the same tree) | not a shortcut — it stats every layer and volume |
| dockerd slow to start after reboot; DSM's ContainerManager sits in `activating` for up to 10 min | dockerd startup does a storm of small I/O over the sick volume, competing with DSM's post-boot media reindex |
| BuildKit "store wedge": a stalled build blocks ALL builds and store queries | a killed/cancelled hung client freed the store instantly (no dockerd restart needed) — see lessons-learned |
| btrfs metadata ENOSPC risk at >90% fill | btrfs flips the volume read-only well before data space runs out; metadata (57 GiB reserved) fills first |

## What the migration changes

| Metric | Before (btrfs graphdriver on btrfs) | After (aufs on ext4 loop) |
|---|---|---|
| CoW per layer write | double (graphdriver + volume) | none (ext4 loop file has `chattr +C`; aufs is non-CoW) |
| Metadata walks (du, rsync scan) | hours for ~100 GB | minutes (ext4) |
| Small-write throughput (dpkg, DB) | ~10× degraded | near-native |
| BuildKit store behavior | wedges under I/O stall | healthy (ext4 handles fsync load) |
| Kernel driver | btrfs graphdriver (deprecated upstream) | aufs (in DSM kernel; no overlayfs on 4.4) |

## Post-migration verification checklist

```bash
docker info | grep -E "Storage Driver|Docker Root Dir"   # aufs, /volume1/@docker-ext4
docker system df                                          # should answer in seconds now
time du -sm /volume1/@docker-ext4                         # minutes, not hours
```

Re-run a representative `docker build` and compare the `dpkg`/restore step
timings — this is where the 10× was.

## What does NOT improve

- The outer btrfs volume (shares, media) is still btrfs — its own performance
  is unchanged. The migration only fixes Docker's data-root.
- `retire-old` is required to actually reclaim the space the old tree holds.
  Until you run it, both trees exist on the volume.
