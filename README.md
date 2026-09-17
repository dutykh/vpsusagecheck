# VPS Usage Check

A single-file shell report for Ubuntu/Debian VPS hosts: network, memory, CPU,
disk and system health, with particular attention to **outgoing bandwidth
against your provider's monthly cap**.

It is designed to be run by hand, or from cron with the output mailed to you
when — and only when — something needs attention.

## Features

- **Monthly bandwidth tracking** from the best source available (`vnstat`,
  Munin RRD, or `/proc/net/dev`), with a **month-end projection** so you learn
  you are on track to blow the cap *before* you do
- **Configurable everything**: limit, count mode and every alert threshold, via
  a config file or environment variables
- **Nagios-compatible exit codes** (0 OK / 1 WARNING / 2 CRITICAL) so cron
  wrappers and monitoring systems can act on the result without parsing text
- **`--json` output** for piping into other tooling
- **Memory, swap, load, CPU, disk and inode** checks with per-resource thresholds
- **System health**: critical services, failed systemd units, reboot-required
  flag, pending security updates, top memory/CPU consumers
- **Colour only when it makes sense** — never when redirected to a log file
- Optional **Munin integration** when Munin is installed

## Requirements

### Essential

- Linux with `/proc` (Ubuntu/Debian assumed, but nothing is distro-locked)
- Bash 4.0 or newer
- GNU coreutils (`df`, `date`, `awk`, `grep`)

### Optional, in order of usefulness

| Tool | What it adds |
|---|---|
| **`vnstat`** | Accurate month-to-date totals that survive reboots. **Strongly recommended** — this is the only source that is both precise and reboot-proof. |
| `rrdtool` + Munin | Month-to-date totals from Munin's own RRD archives |
| `w3m` | Munin plugin problem counts from `problems.html` |
| `systemctl` | Service and failed-unit checks |
| `jq` | Slightly more robust `vnstat` parsing (a `--oneline` fallback is used otherwise) |

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
./munin-check.sh --help          # all options
```

### Options

| Option | Meaning |
|---|---|
| `-j`, `--json` | JSON instead of the text report |
| `--color=WHEN` | `auto` (default), `always`, `never` |
| `--no-color` | Same as `--color=never` |
| `-V`, `--version` | Print version and exit |
| `-h`, `--help` | Print help and exit |

Colour is enabled automatically only when stdout is a terminal. Redirecting to
a file or piping gives clean text, and [`NO_COLOR`](https://no-color.org/) is
honoured.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | OK — nothing crossed a threshold |
| `1` | WARNING — at least one warning threshold crossed |
| `2` | CRITICAL — at least one critical threshold crossed |
| `3` | Usage error (bad option or bad setting) |

## Configuration

Precedence, lowest to highest:

1. Built-in defaults
2. Config file — the first readable of:
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
| `CHECK_REBOOT_REQUIRED` | `1` | Report `/var/run/reboot-required` |
| `CHECK_UPDATES` | `1` | Report pending (security) updates |

Thresholds accept decimals — `DISK_WARN_PCT=87.5` is valid.

## Where the bandwidth number comes from

The report names its source on the `Interface:` line. In order of preference:

1. **`vnstat`** — exact monthly totals, kept in its own database, unaffected by
   reboots. This is what you want.
2. **Munin RRD** — `rrdtool` integrates the stored rate over the month. The
   `if_<iface>-{up,down}-d.rrd` pair is located automatically under
   `MUNIN_RRD_DIR`, matching the default-route interface where possible.
3. **`/proc/net/dev`** — since-boot counters only. Shown for context, but it
   **cannot** tell you your month-to-date usage, so no cap percentage is
   reported and the script records a notice instead.

The **month-end estimate** extrapolates the current month-to-date figure
linearly over the whole month. If that projection exceeds 100% of the cap, the
script raises a warning even while current usage is still comfortable.

> **Accuracy note for anyone upgrading from v1.x:** the old Munin RRD reader
> multiplied the sum of fetched rate samples by the RRD's *base* step (300 s).
> For a month-long window `rrdtool` serves data from a consolidated archive
> whose rows span `pdp_per_row × step` seconds, so the old figure was too low by
> exactly that factor — typically **24×** on a stock Munin `if_` RRD, with the
> factor drifting as the month progressed. v2 hands the integration to
> `rrdtool` itself (`VDEF:…,TOTAL`), which is correct. **Expect the reported
> monthly usage to jump substantially after upgrading** — the new number is the
> right one.

## Automating it

### Daily report by mail, only when something is wrong

The exit code makes this simple and robust — no grepping the output. Put this
in `/usr/local/bin/vps-alert`:

```bash
#!/bin/sh
# Mail the report only when something needs attention.
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

/usr/local/bin/munin-check > "$out" 2>&1
status=$?

if [ "$status" -ge 1 ]; then
    mail -s "VPS alert ($status): $(hostname)" you@example.com < "$out"
fi
exit 0
```

```bash
sudo chmod +x /usr/local/bin/vps-alert
```

```bash
# /etc/cron.d/vpsusagecheck
MAILTO=""
0 6 * * * root /usr/local/bin/vps-alert
```

A predictable path such as `/tmp/vpscheck.out` would be unsafe for a root cron
job, which is why the wrapper uses `mktemp`.

### Unconditional daily log

```bash
0 6 * * * /path/to/vpsusagecheck/munin-check.sh >> /var/log/vps-usage.log 2>&1
```

Output is automatically plain text when redirected, so the log stays readable.

### Feeding another system

```bash
./munin-check.sh --json | jq '.network.projected_pct'
./munin-check.sh --json | jq -r '.issues[] | "\(.level): \(.message)"'
```

The JSON contains `status`, `exit_code`, `network`, `memory`, `load`,
`filesystems[]`, `system` and `issues[]`.

## Understanding the output

| Section | Contents |
|---|---|
| `[NET]` | Interface, data source, month-to-date in/out, metered usage vs cap, month-end estimate, since-boot counters |
| `[MEM]` | Total / used / available memory and swap |
| `[CPU]` | 1/5/15-minute load, core count, load as % of capacity, sampled CPU usage |
| `[DSK]` | Real filesystems only (pseudo-filesystems are skipped), plus inode usage when it is high |
| `[SYS]` | Munin plugin states, critical services, failed units, reboot flag, pending updates, uptime |
| `[TOP]` | Top memory and CPU consumers |
| `[---]` | Host summary, overall status, and every issue found |

Each resource has its own `NOTICE` / `WARNING` / `CRITICAL` thresholds; see the
settings table above. Notices do not affect the exit code; warnings and
criticals do.

## Troubleshooting

### "No month-to-date data available"

No `vnstat`, and no usable Munin RRD. Install `vnstat` (see
[Installation](#installation)) — it is the reliable fix.

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
is normally the metered one — not a Docker bridge or VPN tunnel.

### Permission issues

Most checks read `/proc` and need no privileges. Munin RRDs and
`/var/cache/munin/www` may not be world-readable; run as root or add your user
to the `munin` group if you want those sections.

## Development

```bash
bash -n munin-check.sh     # syntax check
shellcheck munin-check.sh  # lint (also run in CI)
```

CI runs `shellcheck` plus a smoke-test suite on every push and pull request —
see `.github/workflows/lint.yml`.

## Files

| Path | Purpose |
|---|---|
| `munin-check.sh` | The tool |
| `vpsusagecheck.conf.example` | Annotated sample configuration |
| `.github/workflows/lint.yml` | shellcheck + smoke tests |
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

GNU General Public License v3.0 — see [LICENSE](LICENSE).

## Changelog

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
