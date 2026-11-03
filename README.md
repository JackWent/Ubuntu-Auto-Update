# Ubuntu Auto Update

A single bash script that patches an Ubuntu/Debian host unattended — updates,
upgrades, kept-back/phased packages, cleanup — and safely resumes itself
across the reboot(s) that patching often requires, driven entirely by cron.

## What it does

Run start-to-finish, the script works through these steps:

| Step | What happens |
|---|---|
| 1. Pre-check | If `/var/run/reboot-required` already exists (e.g. from a previous manual change), reboot immediately before doing anything else. |
| 2. Update & upgrade | `apt update`, then `apt upgrade -y` (non-interactive). |
| 3. Kept-back packages | `apt dist-upgrade -y` to pull in anything upgrade left held back. |
| 4. Phased updates | Ubuntu's phased-rollout mechanism can hold packages back even after step 3. The script forces them in with `APT::Get::Always-Include-Phased-Updates=true` on both `upgrade` and `dist-upgrade`, then falls back to installing any still-remaining upgradable packages one at a time. |
| 5. Reboot if required | Checks `/var/run/reboot-required` again; reboots if the new packages need it. |
| 6. Cleanup | `apt autoremove -y`, `apt autoclean`, then a final `apt update` + upgradable-package count so the log shows whether anything's still outstanding. |

## Discord report

At the end of a run that installed or removed anything, rebooted, or had a failed apt step, the
script posts one message to Discord: each package with its old and new version, reboots, updates
still pending and any failed steps. A run with nothing to do sends nothing. The webhook URL is read
from `/etc/auto-update/discord-webhook` (root only, mode 600); without that file no report is sent.
Run state for the report is kept in `/var/lib/update-script/` so it survives the reboots.

## Self-resuming across reboots

Steps 2–4 can each trigger a kernel/library update that leaves the host
needing a reboot mid-cycle. Rather than skip rebooting (and leave the host on
an old kernel) or block waiting for one, the script tracks its own progress
in `/var/log/update-script-progress` and calls `reboot` directly when needed:

```
step1_reboot   →  rebooted before any updates ran; resume at step 2
step2_updates  →  finished apt upgrade; resume at step 3
step3_kept_back → finished dist-upgrade; resume at step 4
step4_phased   →  finished phased-update pass; resume at reboot-check/cleanup
```

On a clean run (no progress file), it starts from the top. The progress file
is deleted by `cleanup()` once a full cycle finishes successfully — this is
what makes the `@reboot` cron entry safe to fire on *every* boot without
restarting a finished cycle from scratch.

**Caveat:** because the progress file only gets cleared on successful
completion, a host that's rebooted manually (or power-cycled) in the middle
of a run will resume from wherever it left off on the next boot, rather than
starting a fresh cycle. If you need to force a clean run, delete
`/var/log/update-script-progress` first.

## Requirements

- Ubuntu/Debian host with `apt`, run as (or via `sudo` as) root
- Outbound internet access to the configured apt repositories
- `cron`

## Installation

```bash
sudo install -d -m 0755 /opt/scripts
sudo cp auto-update.sh /opt/scripts/auto-update.sh
sudo chmod +x /opt/scripts/auto-update.sh
```

## Cron setup

Add to root's crontab (`sudo crontab -e`):

```cron
@reboot /opt/scripts/auto-update.sh
0 0 * * * /opt/scripts/auto-update.sh
```

- **`@reboot`** — fires on every boot. This is what lets the script continue
  a patch cycle after it reboots itself mid-run; it's a no-op (just deletes
  nothing, exits after cleanup) if there's no in-progress cycle to resume.
- **`0 0 * * *`** — starts a fresh patch cycle daily at midnight.

## Logging

The script writes progress to stdout/stderr only — it does not redirect to a
log file itself. Under cron, that output either gets mailed to root (if a
local MTA is configured) or silently discarded. To keep a persistent log,
redirect it in the crontab entry instead:

```cron
@reboot /opt/scripts/auto-update.sh >> /var/log/auto-update.log 2>&1
0 0 * * * /opt/scripts/auto-update.sh >> /var/log/auto-update.log 2>&1
```

## Manual usage

```bash
sudo /opt/scripts/auto-update.sh
```

Safe to run by hand at any time — it picks up from `/var/log/update-script-progress`
exactly as cron would.

## Operational notes

- The script **reboots the host automatically and without warning** whenever
  a reboot is flagged as required — expect brief downtime on hosts running
  this on a schedule, especially after kernel updates.
- All `apt` operations run with `DEBIAN_FRONTEND=noninteractive`, so config-file
  prompts are auto-answered with package defaults rather than blocking.
