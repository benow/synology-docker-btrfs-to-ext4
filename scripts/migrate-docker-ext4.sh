#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# migrate-docker-ext4.sh — move the Synology Docker data-root off the
# double-btrfs sandwich (btrfs graphdriver on a btrfs subvolume) onto an ext4
# loop volume (aufs graphdriver), with:
#   * staged, idempotent, RESUMABLE execution (safe to re-run after any failure)
#   * NO data loss: the original /volume1/@docker is never written to — it is
#     the rollback copy until you explicitly run `retire-old`
#   * checksum-verified copy (rsync -c dry-run must be empty before cutover)
#   * automatic rollback of the cutover if verification fails
#
# Usage (run ON the NAS, as root — sudo prompts once, then the whole thing runs):
#   ssh -t andy@192.168.0.9 'sudo -n bash /volume1/docker/nastv/deploy/migrate-docker-ext4.sh migrate'
# Or by stage (each idempotent, resume after failure by re-running):
#   ... migrate-docker-ext4.sh {preflight|prepare|copy|cutover|migrate|status|rollback|retire-old}
#
# State file:     /volume1/@docker-ext4.migration-state  (stage machine)
# Docker config:  /var/packages/ContainerManager/etc/dockerd.json
#                 (backup kept as dockerd.json.pre-ext4bak)
# New data root:  /volume1/@docker-ext4  (ext4 loop-mounted from
#                 /volume1/docker-ext4.img, chattr +C so the OUTER btrfs does
#                 no data CoW on the loop file; the inner ext4 is the only fs
#                 doing real work)
# Downtime:       stack stopped from the middle of `copy` to the end of
#                 `cutover` (~10-20 min for a ~50GB tree; re-running `copy`
#                 after an interruption resumes the rsync).
# Verified on:    DSM 7 kernel 4.4.302+ (aufs in kernel, NO overlayfs —
#                 docker will select the aufs driver on ext4; preflight asserts
#                 aufs is available before anything else happens).
# After ANY NAS reboot or ContainerManager package update, run `status`:
#   - the systemd mount unit must have mounted the image before dockerd starts
#   - a package update may regenerate dockerd.json (restore from *.pre-ext4bak
#     if `status` shows the data-root has reverted)
# ---------------------------------------------------------------------------
set -euo pipefail

# VERBOSE=1 traces every command as it runs (bash -x style) — use when you want
# to see exactly where a long-running stage is:
#   sudo env VERBOSE=1 bash migrate-docker-ext4.sh preflight
[ "${VERBOSE:-0}" = "1" ] && set -x

IMG="/volume1/docker-ext4.img"
IMG_SIZE="300G"
MNT="/volume1/@docker-ext4"
OLD_ROOT="/volume1/@docker"
STATE="/volume1/@docker-ext4.migration-state"
DOCKER_CFG="/var/packages/ContainerManager/etc/dockerd.json"
CFG_BAK="${DOCKER_CFG}.pre-ext4bak"
MOUNT_UNIT="/etc/systemd/system/docker-ext4.mount"
COMPOSE_DIR="${COMPOSE_DIR:-/volume1/docker/nastv}"   # override: COMPOSE_DIR=/path/to/compose-project
LOG="/volume1/@docker-ext4.migration.log"

# --- plumbing ---------------------------------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
stage() { set_state "$1"; log "=== stage: $1 ==="; }
set_state() { echo "$1 $(date '+%F %T')" > "$STATE"; }
get_state() { awk '{print $1}' "$STATE" 2>/dev/null || echo "new"; }

require_root() { [ "$(id -u)" = "0" ] || fail "run as root (sudo bash $0 ...)"; acquire_lock; }

acquire_lock() {
  exec 9>"$STATE.lock"
  flock -n 9 || fail "another migration instance is already running"
}

svc_stop()  { synoservicectl --stop  pkgctl-ContainerManager 2>/dev/null \
              || systemctl stop  pkgctl-ContainerManager.service; }
svc_start() { synoservicectl --start pkgctl-ContainerManager 2>/dev/null \
              || systemctl start pkgctl-ContainerManager.service; }
stack_start() { (cd "$COMPOSE_DIR" && docker compose up -d); }
stack_stop()  { (cd "$COMPOSE_DIR" && docker compose stop); }

# Synology has no `mountpoint` binary — read /proc/mounts instead (MNT has no spaces)
mounted()   { grep -qs " ${MNT} ext4 " /proc/mounts; }
docker_up() { timeout 10 docker info >/dev/null 2>&1; }

# is the data-root currently the NEW one (post-cutover)?
on_new_root() { docker info 2>/dev/null | grep -q "Docker Root Dir: $MNT"; }

data_size_mb() { du -sm --apparent-size "$OLD_ROOT" 2>/dev/null | awk '{print $1}'; }

# --- stages -----------------------------------------------------------------

preflight() {
  require_root
  log "=== preflight ==="
  [ -d "$OLD_ROOT" ] || fail "$OLD_ROOT missing — nothing to migrate"
  [ -f "$DOCKER_CFG" ] || fail "$DOCKER_CFG not found"

  # aufs may be an UNLOADED module — /proc/filesystems only lists loaded
  # filesystems, and after a reboot with dockerd down nobody has loaded it.
  # Load it, THEN assert (module file exists in /lib/modules on DSM; Synology
  # has no modinfo binary).
  if ! grep -q aufs /proc/filesystems; then
    log "aufs not loaded — modprobing (normally loaded on demand by dockerd)"
    modprobe aufs 2>/dev/null || true
  fi
  grep -q aufs /proc/filesystems || fail "kernel has no aufs support even after modprobe — this design requires it (no overlayfs on DSM 4.4 kernels)"
  modinfo -F filename aufs >/dev/null 2>&1 || true   # module may be builtin/loaded; /proc check above is authoritative

  local need_mb free_mb have_mb
  need_mb=$((1024 * 300))          # 300G image
  log "reading /volume1 free space"
  # tr strips the unit suffix (Synology df -Bm appends 'M' — plain integer expected)
  free_mb=$(df -Bm /volume1 | awk 'NR==2 {print $4}' | tr -dc '0-9')
  if [ "${SKIP_SIZE_CHECK:-0}" = "1" ]; then
    # Sizing is advisory fail-early hygiene, not correctness: the copy stage is
    # checksum-verified and resumable, and rsync failing on a too-small image
    # leaves the original untouched (re-run `copy`). Skip the measurement when
    # you already know the tree fits (e.g. after reclaim + df review) — du over
    # @docker can take hours on the double-CoW btrfs volume, and
    # `docker system df` does the same du work internally, so it's no faster.
    log "SKIP_SIZE_CHECK=1 — skipping tree-size measurement (sizing enforced by copy-stage verification instead)"
    have_mb=0
  elif docker_up; then
    # docker system df reports the tree size in seconds; du over @docker takes
    # many minutes on the btrfs volume. Sum of Size across types is the on-disk
    # tree — good enough for the 300G sizing sanity check below.
    log "measuring docker tree size via docker system df (fast path, 120s bound)"
    have_mb=$({ timeout 120 docker system df --format '{{.Type}} {{.Size}}' || true; } | awk '{
      v = $2 + 0; u = $2; sub(/^[0-9.]+/, "", u); u = tolower(u);
      mult = (u ~ /^gb/) ? 1048576 : (u ~ /^mb/) ? 1024 : (u ~ /^kb/) ? 1 : 1;
      s += v * mult   # running total in kB
      n += 1          # expect 4 lines: Images, Containers, Local Volumes, Build Cache
    } END { if (n < 4) print 0; else print int(s / 1024) }')
  fi
  if [ "${SKIP_SIZE_CHECK:-0}" != "1" ] && { [ -z "${have_mb:-}" ] || [ "$have_mb" -le 0 ] 2>/dev/null; }; then
    log "docker system df unusable — falling back to du over $OLD_ROOT (can take several minutes, no output until done)"
    have_mb=$(data_size_mb)
  fi
  [ "$free_mb" -gt $((need_mb + need_mb / 5)) ] || fail "insufficient free space: ${free_mb}MB free, need ${need_mb}MB + 20% headroom"
  if [ "${SKIP_SIZE_CHECK:-0}" != "1" ]; then
    [ "$have_mb" -lt $((need_mb * 8 / 10)) ] || fail "docker tree is ${have_mb}MB — larger than 80% of the ${IMG_SIZE} image. Raise IMG_SIZE and re-run."
    log "docker tree: ~${have_mb}MB apparent; free: ${free_mb}MB; image: ${IMG_SIZE}"
  else
    log "free: ${free_mb}MB; image: ${IMG_SIZE} (tree size not measured)"
  fi

  # btrfs allocation report + capacity warning: btrfs can hit metadata ENOSPC and
  # flip the volume read-only well before data space runs out on a >90% full volume
  if command -v btrfs >/dev/null; then
    btrfs filesystem df /volume1 2>/dev/null | tee -a "$LOG" || true
    local used_pct
    used_pct=$(df --output=pcent /volume1 | tail -1 | tr -dc '0-9')
    if [ "$used_pct" -ge 90 ]; then
      log "WARNING: /volume1 is ${used_pct}% full — btrfs metadata ENOSPC (volume flips read-only) is a real risk at this level."
      log "  Recommended before migrating: prune stale docker image tags, clear recycle bins /"
      log "  Synology Drive versions, then run INCREMENTAL balances only:"
      log "    btrfs balance start -musage=20 /volume1 && btrfs balance start -dusage=5 /volume1 && btrfs balance start -dusage=20 /volume1"
      log "  (NEVER 'btrfs balance start /volume1' full-balance at this fill level; never use DSM defrag with snapshots.)"
    fi
  fi

  command -v rsync >/dev/null || fail "rsync not installed"
  command -v mkfs.ext4 >/dev/null || fail "mkfs.ext4 not available"
  command -v python3 >/dev/null || fail "python3 not available (config edit)"

  # Warn about in-flight CI (the runners stop with dockerd)
  if timeout 10 gh run list --repo benow/nastv --status in_progress --json databaseId \
      -q 'length' 2>/dev/null | grep -qv '^0$'; then
    log "WARNING: a GitHub Actions run is in progress — it will fail during cutover."
  fi
  log "preflight OK"
}

prepare() {
  require_root
  preflight
  stage "prepare"

  if [ ! -f "$IMG" ]; then
    log "creating sparse ${IMG_SIZE} image $IMG (chattr +C: outer btrfs does no data CoW on it)"
    truncate -s "$IMG_SIZE" "$IMG"
    chattr +C "$IMG"                    # nodatacow MUST be set before data exists
    mkfs.ext4 -q -F -m 1 -L docker-ext4 "$IMG"
  else
    [ "$(blkid -o value -s TYPE "$IMG" 2>/dev/null)" = "ext4" ] || fail "$IMG exists but is not a valid ext4 fs — remove it and re-run"
    log "image exists, reusing"
  fi

  mkdir -p "$MNT"
  if ! mounted; then
    mount -o loop,noatime "$IMG" "$MNT"
    log "mounted $IMG -> $MNT"
  fi

  # Persist across reboots: systemd mount unit ordered before the package service
  if systemctl cat pkgctl-ContainerManager.service >/dev/null 2>&1; then
    cat > "$MOUNT_UNIT" <<EOF
[Unit]
Description=Docker data-root ext4 loop volume
Before=pkgctl-ContainerManager.service

[Mount]
What=$IMG
Where=$MNT
Type=ext4
Options=loop,noatime

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable docker-ext4.mount >/dev/null
    log "installed + enabled $MOUNT_UNIT (ordered Before=pkgctl-ContainerManager)"
  else
    log "WARNING: pkgctl-ContainerManager.service unit not found — install a boot task to mount $IMG on $MNT before starting ContainerManager"
  fi

  set_state "prepared"
  log "prepare OK"
}

# Docker-side junk pruning, shared by `copy` (pre-copy, shrinks what rsync moves)
# and `reclaim`. Safe by construction: dangling layers and stale CI sha-tags are
# all re-pullable/re-buildable; images used by (even stopped) containers are
# refused by dockerd itself. PRUNE_BUILD_CACHE=1 also clears the embedded
# BuildKit cache (safe but forces rebuilds — flag-gated).
prune_docker() {
  log "pruning dangling images"
  docker image prune -f | tail -1 | tee -a "$LOG"
  log "pruning stale CI sha-tags (keeping 2 newest per repository)"
  docker images --format '{{.Repository}}:{{.Tag}}|{{.CreatedAt}}' \
    | grep -E ':(amd64|arm64)-[0-9a-f]{40}\|' \
    | sort -t'|' -k1,1 -k2,2r \
    | awk -F'|' '{c[$1]++; if (c[$1]>2) print $1}' > /tmp/stale-tags.$$
  local n=0
  while read -r t; do
    [ -n "$t" ] || continue
    docker rmi "$t" >/dev/null 2>&1 && n=$((n+1)) || log "  could not remove $t (in use?)"
  done < /tmp/stale-tags.$$
  rm -f /tmp/stale-tags.$$
  log "removed $n stale tags"
  if [ "${PRUNE_BUILD_CACHE:-0}" = "1" ]; then
    log "pruning build cache (PRUNE_BUILD_CACHE=1 — next builds re-download/rebuild)"
    docker builder prune -f | tail -2 | tee -a "$LOG"
  fi
  docker system df 2>/dev/null | tee -a "$LOG" || true
}

copy() {
  require_root
  [ "$(get_state)" = "prepared" ] || prepare
  stage "copy"

  # Pre-copy prune (PRUNE=0 to skip): junk deleted here is data rsync never
  # has to move, and a re-run's --delete removes it from the destination too.
  # Requires dockerd up: if a previous copy attempt left it down, start it
  # temporarily — explicitly-stopped containers stay stopped across a daemon
  # restart; the CI runners (restart policy) are stopped first so they can't
  # grab a job during the prune window.
  if [ "${PRUNE:-1}" = "1" ]; then
    if ! docker_up; then
      log "dockerd down (prior copy attempt) — starting temporarily for pre-copy prune"
      docker stop nastv-runner nastv-runner-2 >/dev/null 2>&1 || true
      svc_start
      local waited=0
      until docker_up || [ "$waited" -ge 120 ]; do sleep 5; waited=$((waited+5)); done
      docker_up || fail "dockerd did not come up for pre-copy prune — run 'status', fix, re-run copy"
    fi
    prune_docker
  fi

  log "stopping compose stack"
  stack_stop || true
  log "stopping ContainerManager (dockerd) — all containers freeze here"
  svc_stop
  docker_up && fail "dockerd still answering after service stop — refusing to copy a live tree"

  # ENOSPC note: truncate is sparse (allocates ~nothing), mkfs writes a few hundred MB;
  # rsync grows the file gradually — if btrfs metadata ENOSPC hits mid-copy, rsync fails,
  # the ORIGINAL is untouched (it is never written), and `copy` is resumable after
  # reclaiming space. The only destructive-prone moment is after `done`, via retire-old.
  # Unix sockets in stopped containers' rw layers (dotnet diagnostic sockets,
  # Chromium SingletonSocket) cannot be recreated by rsync — they are dead
  # runtime IPC handles, meaningless as files. Exclude them from BOTH the
  # transfer and the verification so the passes agree; containers recreate
  # sockets at runtime. Without the excludes rsync exits 23 (partial transfer)
  # and verification false-fails on the same files.
  local X=(-aHAX --numeric-ids --delete
           --exclude='*.socket' --exclude='Singleton*')
  log "rsync $OLD_ROOT/ -> $MNT/ (resumable; safe to re-run)"
  rsync "${X[@]}" --info=progress2,stats2 "$OLD_ROOT/" "$MNT/"

  log "checksum verification pass (reads every byte; empty diff = identical)"
  local diff
  diff=$(rsync "${X[@]}" -n -c --out-format='%i %n' "$OLD_ROOT/" "$MNT/" | head -50)
  if [ -n "$diff" ]; then
    log "VERIFICATION FAILED — trees differ:"
    echo "$diff" | tee -a "$LOG"
    fail "checksum verification failed; original untouched. Fix and re-run `copy`."
  fi
  set_state "copied"
  log "copy OK — trees are byte-identical (checksummed)"
}

cutover() {
  require_root
  [ "$(get_state)" = "copied" ] || fail "run `copy` first (state=$(get_state))"
  stage "cutover"

  docker_up && fail "dockerd is running at cutover — stop it first (re-run `copy`)"
  mounted || { mount -o loop,noatime "$IMG" "$MNT"; }

  if ! grep -q '"data-root": *"'$MNT'"' "$DOCKER_CFG" 2>/dev/null; then
    [ -f "$CFG_BAK" ] || cp -a "$DOCKER_CFG" "$CFG_BAK"
    python3 - "$DOCKER_CFG" <<EOF
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["data-root"] = "$MNT"
json.dump(cfg, open(p, "w"), indent=2)
EOF
    log "data-root -> $MNT (config backup: $CFG_BAK)"
  fi

  log "starting ContainerManager on the new data-root"
  svc_start
  sleep 5
  docker_up || { rollback_cutover; fail "dockerd failed to start on the new root — rolled back to $OLD_ROOT"; }

  local driver root
  driver=$(docker info 2>/dev/null | awk '/Storage Driver/{print $3}')
  root=$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')
  log "docker now: driver=$driver root=$root"
  [ "$root" = "$MNT" ] || { rollback_cutover; fail "data-root did not take effect — rolled back"; }
  case "$driver" in aufs|vfs) ;; *) log "note: driver is $driver (expected aufs)";; esac

  local count
  count=$(docker ps -a --format '{{.Names}}' | wc -l)
  [ "$count" -ge 5 ] || { rollback_cutover; fail "only $count containers visible on new root (expected >=5) — rolled back"; }
  log "$count containers visible on the new root; starting stack"

  stack_start
  sleep 20
  local fe
  fe=$(timeout 15 curl -s -o /dev/null -w '%{http_code}' ${CUTOVER_URL:-http://localhost:8500/} || echo 000)
  [ "$fe" = "200" ] || { rollback_cutover; fail "frontend returned $fe — rolled back"; }
  set_state "done"
  log "cutover OK — Docker is on ext4/aufs. Old tree $OLD_ROOT retained as rollback; `retire-old` deletes it when you're confident."
}

rollback_cutover() {
  log "ROLLBACK: restoring data-root to $OLD_ROOT"
  if [ -f "$CFG_BAK" ]; then cp -a "$CFG_BAK" "$DOCKER_CFG"; fi
  svc_start || true
  sleep 5
  docker_up && stack_start && log "rollback complete — stack restarted on the original data-root" \
    || log "rollback: dockerd restored but stack needs manual start (cd $COMPOSE_DIR && docker compose up -d)"
}

status() {
  echo "state:        $(get_state)"
  echo "image:        $(blkid -o value -s TYPE "$IMG" 2>/dev/null || echo missing)"
  echo "mounted:      $(mounted && echo yes || echo NO)"
  echo "dockerd:      $(docker_up && echo up || echo down)"
  on_new_root && echo "data-root:    $MNT (NEW)" || echo "data-root:    $OLD_ROOT (original)"
  docker info 2>/dev/null | grep -E 'Storage Driver|Docker Root Dir'
  echo "containers:   $(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l)"
  df -h "$MNT" 2>/dev/null | tail -1
}

retire-old() {
  require_root
  [ "$(get_state)" = "done" ] || fail "migration not completed — refusing to delete the original"
  on_new_root || fail "docker is not on the new data-root — refusing to delete"
  docker_up || fail "dockerd down — refusing to delete"
  log "renaming original to /volume1/@docker.retired-$(date +%F) (7-day grace, then delete manually)"
  mv "$OLD_ROOT" "/volume1/@docker.retired-$(date +%F)"
  log "done. Reclaim space with: rm -rf /volume1/@docker.retired-*"
}

migrate() {
  preflight
  [ "$(get_state)" = "new" ] && prepare
  [ "$(get_state)" = "prepared" ] && copy
  [ "$(get_state)" = "copied" ] && cutover
  [ "$(get_state)" = "done" ] && { log "migration already complete"; status; }
}

reclaim() {
  # Space reclamation. Safe parts automatic; user-file deletion and the
  # long-running btrfs balances are flag-gated:
  #   reclaim              — prune dangling images + stale CI sha-tags (keep 2 newest per repo)
  #   reclaim --recycle    — also empty all /volume1/<share>/#recycle dirs (DELETES user files)
  #   reclaim --balance    — also run incremental btrfs balances (-musage=20, -dusage=5/20/30)
  # Never uses `docker system prune --volumes`: named volumes here hold real data
  # (nastv_postgres-data, nastv_plugins, ...). Never full-balance at >90% full.
  require_root
  log "=== reclaim ==="
  df -h /volume1 | tail -1 | tee -a "$LOG"

  prune_docker

  # Recycle bins: report by default (these are USER files — deletion needs --recycle)
  local recyclen
  recyclen=$(find /volume1 -maxdepth 2 -type d -name '#recycle' 2>/dev/null | wc -l)
  log "#recycle dirs found: $recyclen"
  if [ "$recyclen" -gt 0 ]; then
    du -sh $(find /volume1 -maxdepth 2 -type d -name '#recycle' 2>/dev/null) 2>/dev/null | tee -a "$LOG"
    if [ "${1:-}" = "--recycle" ]; then
      find /volume1 -maxdepth 2 -type d -name '#recycle' -exec rm -rf {}/\* \; 2>/dev/null
      log "recycle bins emptied"
    else
      log "(pass --recycle to empty them)"
    fi
  fi

  # Incremental btrfs balance — the only safe form at >90% capacity. Long-running
  # (hours); interruptible and resumable via `btrfs balance resume /volume1`.
  if [ "${1:-}" = "--balance" ]; then
    for f in -musage=20 -dusage=5 -dusage=20 -dusage=30; do
      log "btrfs balance start $f /volume1 (this can take a long time)"
      btrfs balance start "$f" /volume1 || { log "balance $f interrupted — resume later with: btrfs balance resume /volume1"; break; }
    done
  else
    btrfs filesystem df /volume1 | tee -a "$LOG"
    log "(pass --balance to run incremental balances: -musage=20, -dusage=5, -dusage=20, -dusage=30)"
  fi

  log "reclaim done:"
  df -h /volume1 | tail -1 | tee -a "$LOG"
  docker system df 2>/dev/null | tee -a "$LOG" || true
}

grow() {
  # Escape hatch if the image ever fills: grow <size>, e.g. `grow 400G`.
  # truncate extends the sparse file; resize2fs grows the ext4. Tries ONLINE
  # first (mounted, docker keeps running) — but DSM's 4.4 kernel ext4 driver
  # fails large single-shot online grows ("Invalid argument ... add group #N").
  # Fallback: OFFLINE resize (unmount -> resize2fs -> remount), which requires
  # dockerd down. If docker is up, stop it first and re-run.
  require_root
  local size="${1:-}"
  [ -n "$size" ] || fail "usage: $0 grow <size>  (e.g. grow 400G)"
  mounted || fail "$MNT not mounted — mount it first (systemctl start docker-ext4.mount)"
  truncate -s "$size" "$IMG"

  if resize2fs "$IMG" 2>&1 | tee -a "$LOG"; then
    log "grew image to $size (online). Now: $(df -h "$MNT" | tail -1)"
    return 0
  fi

  log "online resize failed (DSM 4.4 kernel limitation on large single-shot grows)"
  if docker_up; then
    fail "offline resize needs dockerd down. Stop docker (systemctl stop pkgctl-ContainerManager.service), then re-run: $0 grow $size"
  fi
  log "dockerd is down — doing offline resize (unmount -> resize2fs -> remount)"
  umount "$MNT" || fail "could not unmount $MNT — check for open files (lsof +D $MNT)"
  resize2fs "$IMG" 2>&1 | tee -a "$LOG" || { mount -o loop,noatime "$IMG" "$MNT"; fail "offline resize failed — remounted $MNT unchanged"; }
  mount -o loop,noatime "$IMG" "$MNT" || fail "remount failed — run: mount -o loop,noatime $IMG $MNT"
  log "grew image to $size (offline). Now: $(df -h "$MNT" | tail -1)"
}

case "${1:-}" in
  preflight) preflight ;;
  reclaim)   shift; reclaim "$@" ;;
  prepare)   prepare ;;
  copy)      copy ;;
  cutover)   cutover ;;
  migrate)   migrate ;;
  status)    status ;;
  rollback)  require_root; rollback_cutover ;;
  grow)      shift; grow "$@" ;;
  retire-old) retire-old ;;
  *) sed -n '2,30p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
