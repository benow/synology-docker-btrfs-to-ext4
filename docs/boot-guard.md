# Boot guard: surviving ContainerManager updates

## The threat

A ContainerManager **package update** (and some DSM maintenance events) can
regenerate `/var/packages/ContainerManager/etc/dockerd.json` — silently
reverting `"data-root"` from your ext4 mount (`/volume1/@docker-ext4`) back
to the old btrfs tree (`/volume1/@docker`).

The dangerous part is **not data loss — it's state divergence**:

1. dockerd boots on the *stale* tree. Everything looks normal (old containers
   run), so "it comes up and acts properly" — which is exactly the problem.
2. Any new image, container, or volume write lands on the stale tree.
3. When you later fix the data-root, that work is stranded on btrfs and
   appears to vanish.

A system that boots and runs is not proof of health. Health = dockerd is on
the root it's supposed to be on.

## The design (three layers)

### Layer 1 — auto-repair (silent, common case)

A systemd oneshot service ordered `Before=pkgctl-ContainerManager.service`
runs at every boot. If the ext4 image is mounted AND `dockerd.json` points
elsewhere, it rewrites the data-root key and logs a WARNING to Log Center.

### Layer 2 — hard fail (when repair is impossible)

The same unit exits non-zero when the image is missing/unmounted while the
config points at ext4. Because it's ordered before ContainerManager, the
failed unit blocks the docker start chain: DSM shows the package failed and
raises an admin notification. Docker refuses to run on the wrong filesystem —
loudly, by design.

### Layer 3 — the landmine (after `retire-old`)

Set the retired old subvolume read-only:

```bash
btrfs property set /volume1/@docker.retired-YYYY-MM-DD ro true
```

A read-only btrfs subvolume cannot be written at any level without
deliberately clearing the property. If dockerd ever does start pointing at
the old tree, it fails on its first write — the failure points directly at
the cause instead of silently forking state.

## Logging (find the failure without SSH)

- **Log Center** (DSM UI): `synologset1 sys warning|err "message"` — entries
  appear alongside disk/package warnings with severity colors.
- **Repair instructions in the message itself**: every entry embeds the exact
  command to run, e.g.
  `sudo bash /volume1/docker/nastv/deploy/migrate-docker-ext4.sh status`
- **Admin notification**: `synonotify` pushes the DSM toast to admin browsers
  and mobile DS apps. (Fallback: the blocked package start itself notifies.)
- **Durable trail**: `logger` (→ /var/log/messages) + the guard's own log on
  the data volume (survives DSM major upgrades that reset system logs).

## Standing rule (belt to the guard's suspenders)

**After any NAS reboot or ContainerManager update, run:**

```bash
sudo bash scripts/migrate-docker-ext4.sh status
```

It reports which data-root dockerd is actually on. If it shows the old root,
restore the backup the migration kept:

```bash
sudo cp /var/packages/ContainerManager/etc/dockerd.json.pre-ext4bak \
        /var/packages/ContainerManager/etc/dockerd.json
sudo systemctl restart pkgctl-ContainerManager.service
```

## Known limits

- A **major DSM version upgrade** can wipe user units in
  `/etc/systemd/system/` — including the guard itself. Nothing survives that
  except documentation: this file, the README in the data-root, and the
  `status`-after-updates rule. Reinstall the guard per the README if absent.
- The guard only touches the `data-root` key; it never rewrites the rest of
  `dockerd.json` (package updates may legitimately add settings — the repair
  must preserve them, which is why it edits the key rather than restoring the
  backup file wholesale).

## Implementation status

Planned/verified-in-design as part of the real migration; the guard service
file and its test matrix (simulate reverted config → repair; hide image →
block; rolled-back state → no-op; one real reboot) live with the deployment
that installs them. See the repository README for the current state.
