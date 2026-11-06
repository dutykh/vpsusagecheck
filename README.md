# VPS Usage Check

A single-file shell report for Ubuntu/Debian VPS hosts: network, memory, CPU,
disk and system health, with particular attention to **outgoing bandwidth
against your provider's monthly cap** and to **disk space**: when each disk will
fill at the current pace, which folders hold the space, and what can be freed
safely, with the exact command for each item.

It is designed to be run by hand, or hourly from cron, sending you a short alert
(through the Hermes agent, or any command you choose) only when something needs
attention.

## Features

- **Monthly bandwidth tracking** from the best source available (`vnstat`,
  Munin RRD, or `/proc/net/dev`), with a **month-end projection** so you learn
  you are on track to blow the cap *before* you do
- **Disk forecast**: the growth of each filesystem over the last week, and the
  number of days left before it is full, with a warning well ahead of time
- **Where the space goes**: the largest folders outside the operating system,
  the folders that grew fastest, and large or long-untouched files
- **What can be freed**: package caches, unused pnpm and conda packages, old
  snap revisions, the system journal, Next.js build caches, old remote-server
  versions and more, each with its size and exact command; `--clean` goes through
  the safe ones and asks before each, `--free` frees them without questions
- **Free space by replying to the alert**: with the Hermes agent, answer "free
  everything safe" to an alert and Hermes runs the safe clean-ups for you
- **Alerts** with `--notify`: a short message through the Hermes agent (Telegram,
  WhatsApp, ...) or any command, sent once per new problem, repeated daily while
  it lasts, and followed by an all-clear
- **Configurable everything**: limit, count mode and every alert threshold, via
  a config file or environment variables
- **Nagios-compatible exit codes** (0 OK / 1 WARNING / 2 CRITICAL) so cron
  wrappers and monitoring systems can act on the result without parsing text
- **`--json` output** for piping into other tooling
- **A summary of one line per check** at the end of the report: its verdict,
  the measured values and the thresholds they are held against
- **Memory, swap, load, CPU, disk and inode** checks with per-resource thresholds
- **System health**: critical services, failed systemd units, reboot-required
  flag, pending security updates, top memory/CPU consumers
- **Colour only when it makes sense**: never when redirected to a log file
- Optional **Munin integration** when Munin is installed

## Requirements

### Essential

- Linux with `/proc` (Ubuntu/Debian assumed, but nothing is distro-locked)
- Bash 4.0 or newer
- GNU coreutils (`df`, `date`, `awk`, `grep`)

### Optional, in order of usefulness

| Tool | What it adds |
|---|---|
| **`vnstat`** | Accurate month-to-date totals that survive reboots. **Strongly recommended**: this is the only source that is both precise and reboot-proof. |
| `rrdtool` + Munin | Month-to-date totals from Munin's own RRD archives |
| `w3m` | Munin plugin problem counts from `problems.html` |
| `systemctl` | Service and failed-unit checks |
| `jq` | Slightly more robust `vnstat` parsing (a `--oneline` fallback is used otherwise) |
| `flock`, `ionice`, `timeout` | Safe overlapping runs, an idle-priority folder scan with a time limit (util-linux and coreutils, present on Ubuntu) |
| `hermes` | Alerts through the [Hermes agent](https://github.com/NousResearch/hermes-agent) with `NOTIFY_HERMES_TO` |

Without any of these the script still runs, but bandwidth falls back to
since-boot counters, which cannot answer "how much of my monthly cap have I
used".

## Installation

```bash
git clone https://github.com/dutykh/vpsusagecheck.git
cd vpsusagecheck
chmod +x munin-check.sh
./munin-check.sh
```

Recommended, for meaningful bandwidth numbers:

```bash
sudo apt-get update && sudo apt-get install -y vnstat
sudo systemctl enable --now vnstat
```

`vnstat` needs a little time to accumulate data; totals for the current month
become trustworthy once it has been running for a full billing period.

To install system-wide:

```bash
sudo install -m 0755 munin-check.sh /usr/local/bin/munin-check
sudo install -m 0644 vpsusagecheck.conf.example /etc/vpsusagecheck.conf
```

## Usage

```bash
./munin-check.sh                 # text report
./munin-check.sh --json          # machine-readable
./munin-check.sh --no-color      # force plain text
./munin-check.sh --scan          # rescan the folders now
./munin-check.sh --clean         # free the safe items, asking before each
./munin-check.sh --free list     # the safe items and their names
./munin-check.sh --free all      # free all of them, without questions
./munin-check.sh --help          # all options
```

### Options

| Option | Meaning |
|---|---|
| `-j`, `--json` | JSON instead of the text report |
| `--color=WHEN` | `auto` (default), `always`, `never` |
| `--no-color` | Same as `--color=never` |
| `--scan` | Rescan the folders now instead of using the cached scan |
| `--no-scan` | Never start a folder scan; the cached one, if any, is still shown |
| `--clean` | Offer the safe clean-ups one at a time, asking before each (needs a terminal) |
| `--free WHAT` | Free safe items without asking: `list`, `all`, or names separated by commas (`pnpm-store,npm-cache`) |
| `-y`, `--yes` | With `--clean`: no questions, the same as `--free all` |
| `--notify` | Send an alert when something needs attention (for cron) |
| `--notify-test` | Send a test alert through the configured channel and exit |
| `-q`, `--quiet` | Print nothing (for cron, with `--notify`) |
| `-V`, `--version` | Print version and exit |
| `-h`, `--help` | Print help and exit |

Colour is enabled automatically only when stdout is a terminal. Redirecting to
a file or piping gives clean text, and [`NO_COLOR`](https://no-color.org/) is
honoured.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | OK: nothing crossed a threshold |
| `1` | WARNING: at least one warning threshold crossed |
| `2` | CRITICAL: at least one critical threshold crossed |
| `3` | Usage error (bad option or bad setting) |

## Configuration

Precedence, lowest to highest:

1. Built-in defaults
2. Config file, the first readable of:
   `$VPSUSAGECHECK_CONF`,
   `${XDG_CONFIG_HOME:-$HOME/.config}/vpsusagecheck/config`,
   `$HOME/.vpsusagecheckrc`,
   `/etc/vpsusagecheck.conf`
3. Environment variables
4. Command-line flags

Copy `vpsusagecheck.conf.example` to one of those paths as a starting point.
Every setting below can equally be given as an environment variable:

```bash
BANDWIDTH_LIMIT_TB=20 BANDWIDTH_WARN_PCT=85 ./munin-check.sh
```

### Settings

| Variable | Default | Meaning |
|---|---|---|
| `BANDWIDTH_LIMIT_TB` | `32` | Monthly cap in TiB |
| `BANDWIDTH_COUNT_MODE` | `out` | What the provider meters: `out`, `in`, `sum`, `max` |
| `BANDWIDTH_NOTICE_PCT` | `50` | Notice threshold |
| `BANDWIDTH_WARN_PCT` | `80` | Warning threshold |
| `MEMORY_NOTICE_PCT` | `75` | |
| `MEMORY_WARN_PCT` | `90` | |
| `SWAP_NOTICE_PCT` | `50` | |
| `SWAP_WARN_PCT` | `80` | |
| `LOAD_NOTICE_PCT` | `75` | Load as a percentage of core count |
| `LOAD_WARN_MULTIPLIER` | `1` | Warn when 1-min load > cores × this |
| `DISK_NOTICE_PCT` | `80` | |
| `DISK_WARN_PCT` | `90` | |
| `DISK_CRITICAL_PCT` | `95` | |
| `INODE_NOTICE_PCT` | `80` | |
| `INODE_WARN_PCT` | `90` | |
| `NET_INTERFACE` | auto | Interface to measure; defaults to the default-route interface |
| `MUNIN_RRD_DIR` | `/var/lib/munin` | Where Munin keeps its RRDs |
| `MUNIN_WWW_DIR` | `/var/cache/munin/www` | Where Munin writes its HTML |
| `MUNIN_RRD_UP` / `MUNIN_RRD_DOWN` | auto | Override RRD auto-detection |
| `SHOW_TOP_PROCESSES` | `1` | Show top memory/CPU consumers |
| `TOP_PROCESS_COUNT` | `3` | How many to list |
| `CHECK_FAILED_UNITS` | `1` | Report failed systemd units |
| `IGNORE_FAILED_UNITS` | empty | Failed units that are known and harmless: names or shell patterns such as `cloud-init-*.service`, separated by spaces or commas. They are still named in the report but raise no warning (see [A failed unit that is harmless](#a-failed-unit-that-is-harmless)) |
| `CHECK_REBOOT_REQUIRED` | `1` | Report `/var/run/reboot-required` |
| `CHECK_UPDATES` | `1` | Report pending (security) updates |
| `STATE_DIR` | see below | Where the disk history, the cached scan and the alert memory are kept |
| `DISK_TREND_DAYS` | `7` | Days of history the disk forecast is fitted over |
| `DISK_FILL_NOTICE_DAYS` | `30` | Notice when a disk will be full within this many days |
| `DISK_FILL_WARN_DAYS` | `14` | Warning, same measure |
| `DISK_FILL_CRITICAL_DAYS` | `3` | Critical, same measure |
| `DISK_SCAN` | `1` | `0` turns the folder scan and the savings list off |
| `DISK_SCAN_ROOTS` | auto | Folders to scan, space-separated; default `/home /root /srv /opt /var /usr/local /tmp` plus extra data mounts |
| `DISK_SCAN_DEPTH` | `4` | How deep below each root folder sizes are recorded |
| `DISK_SCAN_MAX_AGE_HOURS` | `12` | How long a scan is reused before `--notify` runs a new one |
| `DISK_SCAN_TIMEOUT` | `600` | Seconds a scan may take before it is stopped |
| `DISK_TOP_COUNT` | `10` | How many large folders to list |
| `DISK_TOP_MIN_MB` | `256` | Smallest folder worth listing |
| `DISK_BIGFILE_MB` | `1024` | Smallest file listed as a large file |
| `DISK_RECLAIM_MIN_MB` | `50` | Smallest saving worth listing |
| `DISK_RECLAIM_NOTICE_GB` | `5` | Notice when at least this much can be freed safely |
| `DISK_JOURNAL_KEEP_MB` | `200` | How much system journal a clean-up keeps |
| `NOTIFY_HERMES_TO` | empty | Hermes delivery target for alerts, e.g. `telegram` |
| `NOTIFY_COMMAND` | empty | Any shell command that sends an alert (see below) |
| `NOTIFY_MIN_LEVEL` | `warning` | Lowest level that triggers an alert: `notice`, `warning`, `critical` |
| `NOTIFY_REPEAT_HOURS` | `24` | Repeat an alert this often while the problem lasts |
| `NOTIFY_RECOVERY` | `1` | Send an all-clear when everything is back to normal |
| `HERMES_BIN` | auto | Path to `hermes`; found on the PATH or in `~/.local/bin` otherwise |

Thresholds accept decimals: `DISK_WARN_PCT=87.5` is valid.

## Disk space: forecast, largest folders and savings

The `[SPC]` section of the report answers three questions about disk space.

**When will the disk be full?** Every run records how much of each filesystem
is in use. The forecast fits a straight line through the last `DISK_TREND_DAYS`
of these records and divides the free space by the daily growth. It needs 12
hours of history before it says anything, so the script has to run regularly
(hourly from cron, see below). It works on the gigabytes actually used, not on
percentages: when a disk is enlarged, the percentage drops overnight while
nothing was deleted, and a forecast built on percentages (Munin's, for
instance) is fooled; this one is not. A sudden burst, a disk that would be full
within `DISK_FILL_CRITICAL_DAYS` at the pace of the last 24 hours, raises its own
warning.

**Where is the space?** A folder scan measures every folder up to
`DISK_SCAN_DEPTH` levels below `/home`, `/root`, `/srv`, `/opt`, `/var`,
`/usr/local`, `/tmp` and any extra data mount; the operating system itself is
left out. The list names the folder a person would recognise: the pnpm store
rather than the home directory that contains it. A folder is listed when at
least half of it is not already explained by smaller folders listed below it.
Each listed folder shows how much it grew over the last week, and the folders
that grew fastest have their own list. The report also says how much of the
used space the scan accounts for, and how many folders the current user could
not read (run as root for a complete picture).

The scan is the one slow part of the report (about a minute for a million files,
more on a cold cache), so it runs at idle priority, is stopped after
`DISK_SCAN_TIMEOUT` seconds, and its result is kept for
`DISK_SCAN_MAX_AGE_HOURS`. A run by hand shows the kept result with its age and
never starts a long scan by surprise; `--scan` refreshes it, and so does the
hourly `--notify` run once the result is older than the limit.

**What can be freed?** Each item comes with its size, its exact command and a
one-line explanation, in two groups.

| Safe to free (rebuilt or downloaded again when needed) | Worth reviewing first |
|---|---|
| pnpm store: packages no installed project links to (`pnpm store prune`) | Rotated logs in `/var/log` |
| npm download cache | Other caches in `~/.cache` (for example browser binaries) |
| | Old pnpm store layouts left by an earlier pnpm major version |
| conda package cache: archives and packages no environment uses | Log files over 200 MB |
| Old snap revisions | Large files untouched for 180 days |
| System journal above `DISK_JOURNAL_KEEP_MB` | Packages `apt autoremove` would remove |
| APT's downloaded package files | Unused Docker images |
| Next.js `.next/cache` build caches | |
| pip, uv, pnpm, yarn, node-gyp and go-build caches in `~/.cache` | |
| Old Warp, VS Code and Cursor remote-server versions (the two newest are kept) | |
| Docker build cache | |

The size of the pnpm and conda items is what their own clean-up would remove:
the files that are not hard-linked into any project or environment. A pnpm store
keeps one layout per major version (`store/v10`, `store/v11`), and
`pnpm store prune` cleans only the layout of the pnpm that runs it; an older
layout is therefore listed for review, with the command that prunes it using the
older pnpm.

`--clean` goes through the safe items, largest first, shows each command and
asks before running it. Items that need root run through `sudo`, which asks for
your password. It measures the space actually freed, and it never touches the
"worth reviewing" group. Run it in a terminal on the server:

```bash
munin-check --clean
```

Each safe item also has a short name, shown in brackets in the report:
`pnpm-store`, `npm-cache`, `conda-pkgs`, `cache:pip`, `next-cache:SITE`,
`old-versions:warp`, `journal`, `apt`, `snaps`, `docker-build`. `--free` uses
these names to free items without asking, which is what a program (or the Hermes
agent) needs:

```bash
munin-check --free list                    # what can be freed now, with names
munin-check --free pnpm-store,npm-cache    # free these two
munin-check --free all                     # free every safe item (= --clean --yes)
```

Without a terminal nobody can type a password, so `--free` runs `sudo -n`: an
item that needs root is reported with the exact command to run by hand, unless
sudo is passwordless for that command.

The report also lists **deleted files still held open** by a running program
(a log removed while the daemon keeps writing to it): the space returns only when
that program restarts. Without root only your own programs are visible.

The history, the cached scan and the alert memory live in `STATE_DIR`:
`/var/lib/vpsusagecheck` when run as root, otherwise
`~/.local/state/vpsusagecheck`. If it cannot be written, the forecast and the
alert memory are switched off and the report says so.

## Where the bandwidth number comes from

The report names its source on the `Interface:` line. In order of preference:

1. **`vnstat`**: exact monthly totals, kept in its own database, unaffected by
   reboots. This is what you want.
2. **Munin RRD**: `rrdtool` integrates the stored rate over the month. The
   `if_<iface>-{up,down}-d.rrd` pair is located automatically under
   `MUNIN_RRD_DIR`, matching the default-route interface where possible.
3. **`/proc/net/dev`**: since-boot counters only. Shown for context, but it
   **cannot** tell you your month-to-date usage, so no cap percentage is
   reported and the script records a notice instead.

The **month-end estimate** extrapolates the current month-to-date figure
linearly over the whole month. If that projection exceeds 100% of the cap, the
script raises a warning even while current usage is still comfortable.

> **Accuracy note for anyone upgrading from v1.x:** the old Munin RRD reader
> multiplied the sum of fetched rate samples by the RRD's *base* step (300 s).
> For a month-long window `rrdtool` serves data from a consolidated archive
> whose rows span `pdp_per_row × step` seconds, so the old figure was too low by
> exactly that factor, typically **24×** on a stock Munin `if_` RRD, with the
> factor drifting as the month progressed. v2 hands the integration to
> `rrdtool` itself (`VDEF:…,TOTAL`), which is correct. **Expect the reported
> monthly usage to jump substantially after upgrading**; the new number is the
> right one.

## Automating it

### Hourly watch with alerts

Run the script every hour with `--notify --quiet`. It records the disk history
the forecast needs, refreshes the folder scan twice a day, and sends a short
alert only when something needs attention:

- when a problem at or above `NOTIFY_MIN_LEVEL` appears, or gets worse;
- again every `NOTIFY_REPEAT_HOURS` while it lasts;
- once more, as an all-clear, when everything is back to normal.

The alert is a few lines of plain text: the disk forecast in one sentence, the
problems (new ones marked), the five largest safe savings with their commands,
and a pointer to `--clean`.

**Through the Hermes agent.** Hermes delivers the alert to any messaging
platform it is configured for, using its own credentials, without involving the
model. If you reply to the alert in that chat, Hermes sees the whole alert as
context, so you can ask it to deal with the problem. In the config file:

```bash
NOTIFY_HERMES_TO=telegram
```

and in the crontab of the user who runs Hermes (`crontab -e`):

```bash
0 * * * * /usr/local/bin/munin-check --notify --quiet
```

Check the channel once with `munin-check --notify-test`. `hermes` is found on
the PATH or in `~/.local/bin`; set `HERMES_BIN` if it lives elsewhere.

**Through any other command.** `NOTIFY_COMMAND` is run by `sh` with the
variables `NOTIFY_SUBJECT`, `NOTIFY_BODY_FILE`, `NOTIFY_LEVEL` and `NOTIFY_HOST`.
Write it in single quotes, since the config file is sourced by bash and double
quotes would expand the variables too early:

```bash
NOTIFY_COMMAND='mail -s "$NOTIFY_SUBJECT" you@example.com < "$NOTIFY_BODY_FILE"'
NOTIFY_COMMAND='tg-ping --title "$NOTIFY_SUBJECT" < "$NOTIFY_BODY_FILE"'
```

Both channels may be set; an alert counts as delivered when one of them succeeds.
A failed delivery is retried at the next run.

### Freeing space by replying to an alert

With Hermes as the channel, the alert ends with "reply to this message to free
them". Reply "free everything safe", or name the items ("free the pnpm store and
the npm cache"), and Hermes runs `munin-check --free` on the server, then answers
with the space freed and the free space left. Hermes never deletes anything
itself: `--free` can only perform the safe clean-ups listed above, and the skill
that teaches Hermes this procedure forbids every other deleting command, sudo and
password requests.

Install the skill once, as the user who runs Hermes:

```bash
mkdir -p ~/.hermes/skills/devops/vps-disk-cleanup
cp ~/tools/vpsusagecheck/hermes/vps-disk-cleanup/SKILL.md ~/.hermes/skills/devops/vps-disk-cleanup/
```

The items that need root (`journal`, `apt`, `snaps`) come back with the command
for you to paste. To let Hermes do the journal and the APT cache as well, allow
exactly these two commands without a password (`sudo visudo -f
/etc/sudoers.d/vpsusagecheck`, replacing `dds` by that user):

```text
dds ALL=(root) NOPASSWD: /usr/bin/journalctl --vacuum-size=200M, /usr/bin/apt-get clean
```

Old snap revisions stay manual: a sudo rule for `snap remove` could not be
narrowed to old revisions.

### Unconditional daily log

```bash
0 6 * * * /path/to/vpsusagecheck/munin-check.sh >> /var/log/vps-usage.log 2>&1
```

Output is automatically plain text when redirected, so the log stays readable.

### Feeding another system

```bash
./munin-check.sh --json | jq '.network.projected_pct'
./munin-check.sh --json | jq -r '.issues[] | "\(.level): \(.message)"'
./munin-check.sh --json | jq '.disk_analysis.trends[] | {mount, days_to_full}'
```

The JSON contains `status`, `exit_code`, `network`, `memory`, `load`,
`filesystems[]`, `disk_analysis`, `system` and `issues[]`. `disk_analysis`
holds `trends[]`, `scan`, `coverage[]`, `largest_dirs[]`, `growing_dirs[]`,
`large_files[]`, `savings[]` with their totals, and `deleted_open[]`. Every
issue carries a stable `key` naming the kind of problem.

## Understanding the output

| Section | Contents |
|---|---|
| `[NET]` | Interface, data source, month-to-date in/out, metered usage vs cap, month-end estimate, since-boot counters |
| `[MEM]` | Total / used / available memory and swap |
| `[CPU]` | 1/5/15-minute load, core count, load as % of capacity, sampled CPU usage |
| `[DSK]` | Real filesystems only (pseudo-filesystems are skipped), plus inode usage when it is high |
| `[SPC]` | Disk forecast, folder scan, largest and fastest-growing folders, large files, what can be freed, deleted files still held open |
| `[SYS]` | Munin plugin states, critical services, failed units, reboot flag, pending updates, uptime |
| `[TOP]` | Top memory and CPU consumers |
| `[---]` | The host, one line per check with its verdict, values and thresholds, and the overall status |

Each resource has its own `NOTICE` / `WARNING` / `CRITICAL` thresholds; see the
settings table above. Notices do not affect the exit code; warnings and
criticals do.

### The summary

The report ends with one line per check, so that a glance tells what was
tested, what was measured and how far each value stands from its thresholds. A
typical run on a quiet server:

```text
[---] SUMMARY
--------------------------------------------------------------------
  myvps: Ubuntu 26.04.1 LTS, Linux 7.0.0-43-generic (x86_64), run as dds, up 40 minutes

  OK        Bandwidth     4.08 GB sent, 0.01% of 32 TB (notice >50%, warning >80%); month end 0.07% (warning >100%)
  OK        Memory        3.74 GB of 62.79 GB in use, 6.0% (notice >75%, warning >90%)
  N/A       Swap          no swap space on this machine
  OK        Load          1-minute load 0.32 on 16 cores, 2.0% of capacity (notice >75%, warning >100%)
  OK        Disk space    / 9%, /boot 18%, /boot/efi 7% (notice >80%, warning >90%, critical >95%)
  OK        Inodes        / 2%, /boot 1% (notice >80%, warning >90%)
  OK        Disk growth   nothing filling up over the last 6 days (notice <30 days left, warning <14, critical <3)
  OK        Reclaimable   3.51 GB safe in 6 items, 514.70 MB to review, scan 43 min ago (notice from 5 GB safe)
  OK        Deleted files none held open by the programs of dds (notice from 500.00 MB)
  OK        Munin         0 critical, 0 warning, 0 unknown plugin states
  OK        Services      ssh and cron running
  OK        Failed units  none
  OK        Reboot        not needed
  OK        Updates       none pending (warning on any security update)

Overall status: OK (exit 0), nothing needs attention
```

The first column is the verdict. `OK`, `NOTICE`, `WARNING` and `CRITICAL` come
from the very problems that set the exit code and trigger the alerts, so the
summary can never disagree with them; a line that crosses a threshold reads, for
instance,
`WARNING   Memory        57.33 GB of 62.79 GB in use, 91.3% (notice >75%, warning >90%)`.
`OFF` marks a check switched off by a setting (`CHECK_UPDATES=0`, `DISK_SCAN=0`,
a state directory that cannot be written), and `N/A` a check with nothing to
measure on this machine (no swap, no Munin, no systemd). The thresholds in
parentheses are the configured ones; a percentage must exceed its threshold to
count, and a disk is flagged when fewer days than stated are left before it is
full. The Disk growth line names the filesystem that will be full soonest, and
mentions a burst of the last 24 hours when one was recorded; the Reclaimable line
says how old the folder scan behind it is. Should a future check record a problem
that no line covers, it is printed under the name `Other`, and the last line
counts the warnings and notices.

## Troubleshooting

### "No month-to-date data available"

No `vnstat`, and no usable Munin RRD. Install `vnstat` (see
[Installation](#installation)): it is the reliable fix.

### Bandwidth source shows `proc`

The same cause. `/proc/net/dev` only knows about traffic since the last reboot,
so cap tracking is impossible from it.

### Munin RRDs are not being found

Check that the pair exists and that its interface matches:

```bash
ls /var/lib/munin/*/*-if_*-{up,down}-d.rrd
ip route show default          # the interface the script looks for first
```

Point the script at them explicitly if auto-detection picks wrong:

```bash
MUNIN_RRD_UP=/var/lib/munin/<domain>/<host>-if_ens3-up-d.rrd \
MUNIN_RRD_DOWN=/var/lib/munin/<domain>/<host>-if_ens3-down-d.rrd \
./munin-check.sh
```

Verify Munin is actually collecting:

```bash
sudo systemctl status munin-node
sudo -u munin munin-cron
```

### The wrong interface is measured

```bash
NET_INTERFACE=ens3 ./munin-check.sh
```

By default the script measures the interface carrying the default route, which
is normally the metered one, not a Docker bridge or VPN tunnel.

### Permission issues

Most checks read `/proc` and need no privileges. Munin RRDs and
`/var/cache/munin/www` may not be world-readable; run as root or add your user
to the `munin` group if you want those sections. The folder scan skips what the
current user cannot read and says how many folders that was.

### The disk forecast says "collecting history"

The forecast needs at least three samples spanning 12 hours. Run the script
hourly from cron (see [Hourly watch with alerts](#hourly-watch-with-alerts)).

### A failed unit that is harmless

The `Failed units` line, and with it the warning and the exit code 1, names every
systemd unit in the failed state. On some VPS images one of them is
`cloud-init-main.service`: the provider's first-boot setup runs a command of its
own from the configuration disc attached to the machine, that command ends with
an error, and systemd then marks the whole unit as failed although the server
works. `cloud-init status --long` names the step that failed. Once you
have looked at the reason for a failure and decided that it does not matter, list
the unit in the configuration file:

```bash
IGNORE_FAILED_UNITS=cloud-init-main.service
```

Several units are separated by spaces or commas, and shell patterns are allowed
(`cloud-init-*.service`). The unit is still named in the report, as
`Failed units:  none (ignored: cloud-init-main.service)`, and in the `--json`
output under `failed_units_ignored`, but it no longer raises a warning, changes
the exit code or triggers an alert. Any other unit that fails is reported as
before.

### Alerts do not arrive

```bash
munin-check --notify-test
```

prints why a channel failed. Under cron the PATH is minimal: set `HERMES_BIN` to
the full path of `hermes` if it is not in `~/.local/bin`.

## Development

```bash
bash -n munin-check.sh     # syntax check
shellcheck munin-check.sh  # lint
```

Both are run by hand before a change goes in. The script can also be sourced
(`. ./munin-check.sh`) to call a single function in a test; it only runs
`main` when executed.

## Files

| Path | Purpose |
|---|---|
| `munin-check.sh` | The tool |
| `vpsusagecheck.conf.example` | Annotated sample configuration |
| `hermes/vps-disk-cleanup/SKILL.md` | Hermes skill: free space when you reply to an alert |
| `.shellcheckrc` | Lint configuration |
| `README.md` | This document |
| `LICENSE` | GNU GPL v3 |

## Author

Dr. Denys Dutykh (Khalifa University of Science and Technology, Abu Dhabi, UAE)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `shellcheck munin-check.sh` and test on an Ubuntu host
5. Submit a pull request

## License

GNU General Public License v3.0, see [LICENSE](LICENSE).

## Changelog

### v2.3.0

**Changed**

- The summary at the end of the report gives one line per check (bandwidth,
  memory, swap, load, disk space, inodes, disk growth, reclaimable space, deleted
  files still open, Munin, services, failed units, reboot, updates), each with
  its verdict, the measured values and the thresholds they are held against,
  then the overall status with the number of warnings and notices. The verdict
  of a line comes from the same recorded problems as the exit code and the
  alerts. The list of problem messages that the summary used to print is gone
  from the text report, since each problem now sits on its own line; the JSON
  output and the alert message are unchanged.

**Fixed**

- Without `jq`, the month's traffic was read from fields 14 and 15 of
  `vnstat --oneline`, which hold the all-time totals, so that a host without
  `jq` reported its whole history as this month's usage. Fields 9 and 10, the
  current month, are now read.
- Between the notice and the warning thresholds, a month heading past the cap
  raised only the notice, because the month-end projection was tested only below
  the notice threshold; the same projection below that threshold gave a warning.
  The projection is now tested whenever the warning on current usage has not
  been raised already.

### v2.2.0

**Added**

- `IGNORE_FAILED_UNITS`: failed systemd units that are known and harmless (for
  example `cloud-init-main.service` on a VPS whose provider's first-boot command
  exits with an error) can be listed by name or shell pattern. The report still
  names them, as `Failed units:  none (ignored: ...)`, and the JSON output lists
  them under `failed_units_ignored`, but they no longer raise a warning, change
  the exit code or trigger an alert.

### v2.1.0

**Added**

- Disk forecast: daily growth of each filesystem fitted over the last week, the
  days left before it is full, with notice, warning and critical levels
  (`DISK_FILL_*_DAYS`) and a separate alert for a sudden burst. It works on the
  bytes in use, so enlarging a disk does not upset it.
- Folder scan of the non-system folders: largest folders, folders that grew
  fastest, large and long-untouched files, and how much of the used space the
  scan accounts for. Cached, idle priority, time-limited.
- Savings list with sizes and exact commands, split into safe items and items
  worth reviewing, and `--clean` to free the safe ones interactively.
- `--free list|all|NAME,...` and `--clean --yes` to free safe items without
  questions, by their short names, and a Hermes skill
  (`hermes/vps-disk-cleanup`) so that replying to an alert frees the space.
- Deleted files still held open by running programs.
- Alerts with `--notify` through the Hermes agent (`NOTIFY_HERMES_TO`) or any
  command (`NOTIFY_COMMAND`): sent once per new problem, repeated every
  `NOTIFY_REPEAT_HOURS`, followed by an all-clear. `--notify-test`.
- `--scan`, `--no-scan`, `--quiet`.
- A stable `key` for every issue, in the JSON output too, and a
  `disk_analysis` object in the JSON.

**Removed**

- The GitHub Actions workflow; `bash -n` and `shellcheck` are run by hand.
- The `vps-alert` mail wrapper from the README, superseded by `--notify`.

### v2.0.0

**Fixed**

- **Monthly bandwidth from Munin RRDs was under-reported by the RRA
  consolidation factor** (typically 24×). `rrdtool` now performs the
  rate-to-volume integration itself. See the accuracy note above.
- Munin RRD paths are auto-detected instead of being hardcoded to
  `localhost.localdomain-if_eth0-*`, which silently failed on any host with a
  different node name or interface and dropped the report to since-boot data.
- Decimal thresholds (e.g. `DISK_WARN_PCT=90.5`) no longer raise
  `integer expression expected`; disk and inode checks now use the same
  float-safe comparison as every other resource.
- Filesystems for which `df` reports `-` instead of a percentage no longer
  produce shell errors.
- Service detection is no longer subject to a `pipefail`/`SIGPIPE` race that
  intermittently reported running services as missing.
- The measured interface is the default-route interface rather than the first
  one with traffic, which could be a Docker bridge or tunnel.
- `LC_ALL=C` is set, so decimal separators in non-English locales no longer
  break numeric comparisons.
- The report header box is no longer misaligned.

**Added**

- Exit codes 0/1/2/3 for cron and monitoring integration
- `--json` machine-readable output
- `--help`, `--version`, `--color=WHEN`, `--no-color`
- Config file support with documented precedence, plus
  `vpsusagecheck.conf.example`
- `BANDWIDTH_COUNT_MODE` (`out` / `in` / `sum` / `max`)
- `vnstat` as the preferred bandwidth source
- Month-end usage projection, with a warning when the cap is on track to be exceeded
- Swap thresholds, failed systemd units, reboot-required flag, pending security
  updates, top memory/CPU consumers
- Colour auto-detection and `NO_COLOR` support
- shellcheck + smoke-test CI

**Changed**

- Emoji and box-drawing characters replaced with ASCII markers, so the report
  stays aligned in log files and non-UTF-8 terminals
- Internals reorganised into collection and rendering phases behind a `main()`

### v1.0.0

- Initial release: 32 TB bandwidth tracking, Munin integration with fallback,
  colour-coded memory, CPU, disk and network monitoring
- Configurable thresholds via environment variables
