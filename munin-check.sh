#!/usr/bin/env bash
#
# vpsusagecheck - VPS resource usage report with monthly outbound bandwidth tracking.
#
# Reports network, memory, CPU, disk and system health, and warns before you run
# into your provider's monthly outbound bandwidth cap. For disk space it also
# forecasts when each filesystem will fill, names the largest and fastest-growing
# folders, lists what can be freed and how, and can alert the administrator.
#
# Author:  Dr. Denys Dutykh (Khalifa University of Science and Technology, Abu Dhabi, UAE)
# License: GPL-3.0-or-later
# Docs:    README.md
#
# Strict mode note: `set -e` is deliberately NOT enabled. This is a reporting
# tool - aborting halfway through would hide the very information it exists to
# show, and on a cron run the truncated output looks like a healthy short report.
# Every fallible command is guarded explicitly instead.
set -uo pipefail

# Deterministic parsing and decimal separators regardless of the caller's locale.
# Without this, awk's printf can emit "0,5" under e.g. fr_FR, breaking every
# numeric comparison in the script.
export LC_ALL=C

readonly VERSION="2.3.0"
readonly PROGNAME="${0##*/}"

# Exit codes (Nagios-compatible).
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_USAGE=3

readonly BYTES_PER_TIB=1099511627776

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Precedence, lowest to highest: built-in default < config file < environment
# variable < command-line flag.

# Every knob that may be set in a config file or the environment.
readonly CONFIG_KEYS=(
    BANDWIDTH_LIMIT_TB BANDWIDTH_NOTICE_PCT BANDWIDTH_WARN_PCT BANDWIDTH_COUNT_MODE
    MEMORY_NOTICE_PCT MEMORY_WARN_PCT
    SWAP_NOTICE_PCT SWAP_WARN_PCT
    LOAD_NOTICE_PCT LOAD_WARN_MULTIPLIER
    DISK_NOTICE_PCT DISK_WARN_PCT DISK_CRITICAL_PCT
    INODE_NOTICE_PCT INODE_WARN_PCT
    NET_INTERFACE MUNIN_RRD_UP MUNIN_RRD_DOWN MUNIN_RRD_DIR MUNIN_WWW_DIR
    SHOW_TOP_PROCESSES TOP_PROCESS_COUNT
    CHECK_FAILED_UNITS IGNORE_FAILED_UNITS CHECK_REBOOT_REQUIRED CHECK_UPDATES
    STATE_DIR
    DISK_TREND_DAYS DISK_FILL_NOTICE_DAYS DISK_FILL_WARN_DAYS DISK_FILL_CRITICAL_DAYS
    DISK_SCAN DISK_SCAN_ROOTS DISK_SCAN_DEPTH DISK_SCAN_MAX_AGE_HOURS DISK_SCAN_TIMEOUT
    DISK_TOP_COUNT DISK_TOP_MIN_MB DISK_BIGFILE_MB
    DISK_RECLAIM_MIN_MB DISK_RECLAIM_NOTICE_GB DISK_JOURNAL_KEEP_MB
    NOTIFY_HERMES_TO NOTIFY_COMMAND NOTIFY_MIN_LEVEL NOTIFY_REPEAT_HOURS NOTIFY_RECOVERY
    HERMES_BIN
)

# Config file search order; the first readable one wins.
config_candidates() {
    if [ -n "${VPSUSAGECHECK_CONF:-}" ]; then
        printf '%s\n' "$VPSUSAGECHECK_CONF"
        return
    fi
    printf '%s\n' \
        "${XDG_CONFIG_HOME:-$HOME/.config}/vpsusagecheck/config" \
        "$HOME/.vpsusagecheckrc" \
        "/etc/vpsusagecheck.conf"
}

CONFIG_FILE=""
load_config_file() {
    local candidate
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ -r "$candidate" ]; then
            CONFIG_FILE="$candidate"
            # shellcheck source=/dev/null
            . "$candidate" || {
                printf '%s: warning: failed to load config file %s\n' \
                    "$PROGNAME" "$candidate" >&2
                CONFIG_FILE=""
            }
            return
        fi
    done < <(config_candidates)
}

# Values that came from the environment outrank the config file, so snapshot
# them before sourcing it and restore them afterwards.
apply_configuration() {
    local key envsnap
    for key in "${CONFIG_KEYS[@]}"; do
        if [ -n "${!key+set}" ]; then
            printf -v "_ENV_$key" '%s' "${!key}"
        fi
    done

    load_config_file

    for key in "${CONFIG_KEYS[@]}"; do
        envsnap="_ENV_$key"
        if [ -n "${!envsnap+set}" ]; then
            printf -v "$key" '%s' "${!envsnap}"
        fi
    done
}
apply_configuration

# Bandwidth
BANDWIDTH_LIMIT_TB="${BANDWIDTH_LIMIT_TB:-32}"
BANDWIDTH_NOTICE_PCT="${BANDWIDTH_NOTICE_PCT:-50}"
BANDWIDTH_WARN_PCT="${BANDWIDTH_WARN_PCT:-80}"
# What the provider actually meters: out | in | sum | max
BANDWIDTH_COUNT_MODE="${BANDWIDTH_COUNT_MODE:-out}"

# Memory / swap
MEMORY_NOTICE_PCT="${MEMORY_NOTICE_PCT:-75}"
MEMORY_WARN_PCT="${MEMORY_WARN_PCT:-90}"
SWAP_NOTICE_PCT="${SWAP_NOTICE_PCT:-50}"
SWAP_WARN_PCT="${SWAP_WARN_PCT:-80}"

# Load
LOAD_NOTICE_PCT="${LOAD_NOTICE_PCT:-75}"
LOAD_WARN_MULTIPLIER="${LOAD_WARN_MULTIPLIER:-1}"

# Disk / inodes
DISK_NOTICE_PCT="${DISK_NOTICE_PCT:-80}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
DISK_CRITICAL_PCT="${DISK_CRITICAL_PCT:-95}"
INODE_NOTICE_PCT="${INODE_NOTICE_PCT:-80}"
INODE_WARN_PCT="${INODE_WARN_PCT:-90}"

# Data sources (empty = auto-detect)
NET_INTERFACE="${NET_INTERFACE:-}"
MUNIN_RRD_UP="${MUNIN_RRD_UP:-}"
MUNIN_RRD_DOWN="${MUNIN_RRD_DOWN:-}"
MUNIN_RRD_DIR="${MUNIN_RRD_DIR:-/var/lib/munin}"
MUNIN_WWW_DIR="${MUNIN_WWW_DIR:-/var/cache/munin/www}"

# Optional extra checks
SHOW_TOP_PROCESSES="${SHOW_TOP_PROCESSES:-1}"
TOP_PROCESS_COUNT="${TOP_PROCESS_COUNT:-3}"
CHECK_FAILED_UNITS="${CHECK_FAILED_UNITS:-1}"
# Failed units that are known and harmless: names or shell patterns, separated by
# spaces or commas. The report still names them, but they raise no warning.
IGNORE_FAILED_UNITS="${IGNORE_FAILED_UNITS:-}"
CHECK_REBOOT_REQUIRED="${CHECK_REBOOT_REQUIRED:-1}"
CHECK_UPDATES="${CHECK_UPDATES:-1}"

# Where the disk history, the cached folder scan and the notification memory
# are kept (empty = /var/lib/vpsusagecheck for root, else
# ${XDG_STATE_HOME:-~/.local/state}/vpsusagecheck).
STATE_DIR="${STATE_DIR:-}"

# Disk forecast: days of history the trend is fitted over, and how many days
# before a filesystem fills each level is raised.
DISK_TREND_DAYS="${DISK_TREND_DAYS:-7}"
DISK_FILL_NOTICE_DAYS="${DISK_FILL_NOTICE_DAYS:-30}"
DISK_FILL_WARN_DAYS="${DISK_FILL_WARN_DAYS:-14}"
DISK_FILL_CRITICAL_DAYS="${DISK_FILL_CRITICAL_DAYS:-3}"

# Folder scan and savings (DISK_SCAN_ROOTS empty = the non-system defaults).
DISK_SCAN="${DISK_SCAN:-1}"
DISK_SCAN_ROOTS="${DISK_SCAN_ROOTS:-}"
DISK_SCAN_DEPTH="${DISK_SCAN_DEPTH:-4}"
DISK_SCAN_MAX_AGE_HOURS="${DISK_SCAN_MAX_AGE_HOURS:-12}"
DISK_SCAN_TIMEOUT="${DISK_SCAN_TIMEOUT:-600}"
DISK_TOP_COUNT="${DISK_TOP_COUNT:-10}"
DISK_TOP_MIN_MB="${DISK_TOP_MIN_MB:-256}"
DISK_BIGFILE_MB="${DISK_BIGFILE_MB:-1024}"
DISK_RECLAIM_MIN_MB="${DISK_RECLAIM_MIN_MB:-50}"
DISK_RECLAIM_NOTICE_GB="${DISK_RECLAIM_NOTICE_GB:-5}"
DISK_JOURNAL_KEEP_MB="${DISK_JOURNAL_KEEP_MB:-200}"

# Notifications, sent only with --notify (empty target and command = none).
NOTIFY_HERMES_TO="${NOTIFY_HERMES_TO:-}"
NOTIFY_COMMAND="${NOTIFY_COMMAND:-}"
NOTIFY_MIN_LEVEL="${NOTIFY_MIN_LEVEL:-warning}"
NOTIFY_REPEAT_HOURS="${NOTIFY_REPEAT_HOURS:-24}"
NOTIFY_RECOVERY="${NOTIFY_RECOVERY:-1}"
HERMES_BIN="${HERMES_BIN:-}"

# ---------------------------------------------------------------------------
# Output mode
# ---------------------------------------------------------------------------
OUTPUT_FORMAT="text"
COLOR_WHEN="auto"
RUN_MODE="report"     # report | clean | free | notify-test
FREE_REQUEST=""       # --free: "list", "all" or item names separated by commas
CLEAN_NONINTERACTIVE=0
ASSUME_YES=0          # --yes: --clean without the questions (same as --free all)
SCAN_MODE="auto"      # auto | force (--scan) | skip (--no-scan)
NOTIFY_MODE=0         # 1 with --notify
QUIET=0               # 1 with --quiet

RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' NC='' BOLD=''

setup_colors() {
    local enable=0
    case "$COLOR_WHEN" in
        always) enable=1 ;;
        never)  enable=0 ;;
        auto)
            # Honour https://no-color.org/, and never colourise a redirected
            # stream - the README recommends cron-redirecting to a log file.
            if [ -n "${NO_COLOR:-}" ] || [ "$OUTPUT_FORMAT" = "json" ]; then
                enable=0
            elif [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
                enable=1
            fi
            ;;
    esac

    if [ "$enable" -eq 1 ]; then
        RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'; PURPLE=$'\033[0;35m'; CYAN=$'\033[0;36m'
        NC=$'\033[0m';     BOLD=$'\033[1m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' NC='' BOLD=''
    fi
}

# ---------------------------------------------------------------------------
# Status tracking
# ---------------------------------------------------------------------------
OVERALL_STATUS=$EXIT_OK
ISSUES=()
ISSUE_KEYS=()

# record_issue <level: notice|warning|critical> <message> [key]
#
# The key names the kind of finding and stays the same from one run to the
# next, while the message carries the current figures. Notification
# de-duplication compares keys, never messages, so "Memory usage at 91.2%"
# followed by "... 91.4%" is one ongoing condition, not two alerts.
record_issue() {
    local level="$1" message="$2" key="${3:-$2}"
    ISSUES+=("$level|$message")
    ISSUE_KEYS+=("$key")
    case "$level" in
        critical) OVERALL_STATUS=$EXIT_CRITICAL ;;
        warning)
            [ "$OVERALL_STATUS" -lt "$EXIT_WARNING" ] && OVERALL_STATUS=$EXIT_WARNING
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

# True when the argument looks like a number we can do arithmetic on.
is_number() {
    case "${1:-}" in
        ''|*[!0-9.eE+-]*) return 1 ;;
    esac
    awk -v v="$1" 'BEGIN {exit !(v == v + 0)}' 2>/dev/null
}

# Float-safe comparison: succeeds when $1 > $2. Non-numeric input never fires.
compare_gt() {
    if ! is_number "${1:-}" || ! is_number "${2:-}"; then return 1; fi
    awk -v left="$1" -v right="$2" 'BEGIN {exit !(left > right)}'
}

bytes_to_human() {
    local bytes="${1:-}"
    is_number "$bytes" || { printf 'n/a'; return; }
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", unit, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, unit[i]
        else        printf "%.2f %s", b, unit[i]
    }'
}

kb_to_human() {
    local kb="${1:-}"
    is_number "$kb" || { printf 'n/a'; return; }
    bytes_to_human "$(awk -v k="$kb" 'BEGIN {printf "%.0f", k * 1024}')"
}

repeat_char() {
    local char="$1" count="$2" out=""
    while [ "$count" -gt 0 ]; do out+="$char"; count=$((count - 1)); done
    printf '%s' "$out"
}

is_ignored_fs_type() {
    case "$1" in
        tmpfs|devtmpfs|proc|sysfs|overlay|squashfs|*squash*|efivarfs|cgroup|cgroup2|\
debugfs|tracefs|pstore|securityfs|mqueue|fusectl|configfs|autofs|ramfs|hugetlbfs|\
binfmt_misc|bpf|nsfs|devpts|rpc_pipefs|fuse.gvfsd-fuse|fuse.portal|iso9660)
            return 0 ;;
        *)  return 1 ;;
    esac
}

service_exists() {
    local name="$1"
    if command_exists systemctl; then
        # Deliberately not `list-unit-files | grep -q`: under `pipefail` that
        # pipeline returns 141 whenever grep exits before systemctl finishes
        # writing, which made service detection fail intermittently.
        [ "$(systemctl show -p LoadState --value "${name}.service" 2>/dev/null)" \
            = "loaded" ]
        return $?
    fi
    [ -x "/etc/init.d/$name" ]
}

service_is_active() {
    local name="$1"
    if command_exists systemctl; then
        systemctl is-active "$name" >/dev/null 2>&1
        return $?
    fi
    if command_exists service; then
        service "$name" status >/dev/null 2>&1
        return $?
    fi
    return 1
}

json_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

json_num() {
    # Emit a bare JSON number, or null when the value is not numeric.
    if is_number "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi
}

warn() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; }

# run_limited <seconds> <command...>: the command under timeout(1) when it exists.
run_limited() {
    local limit="$1"; shift
    if command_exists timeout; then timeout "$limit" "$@"; else "$@"; fi
}

mb_to_kb() { awk -v m="${1:-0}" 'BEGIN {printf "%.0f", m * 1024}'; }

# A signed size for rates and changes: "+1.62 GB", "-300.00 MB".
signed_kb_to_human() {
    local kb="${1:-}"
    is_number "$kb" || { printf 'n/a'; return; }
    if compare_gt 0 "$kb"; then
        printf -- '-%s' "$(kb_to_human "$(awk -v k="$kb" 'BEGIN {printf "%.0f", -k}')")"
    else
        printf '+%s' "$(kb_to_human "$kb")"
    fi
}

# "just now", "25 min ago", "3 h ago", "2 days ago".
human_age() {
    awk -v s="${1:-0}" 'BEGIN {
        if (s < 90)          print "just now"
        else if (s < 5400)   printf "%.0f min ago\n", s / 60
        else if (s < 172800) printf "%.0f h ago\n", s / 3600
        else                 printf "%.0f days ago\n", s / 86400
    }'
}

# "about 9 hours", "about a day", "about 12 days".
days_phrase() {
    awk -v d="${1:-0}" 'BEGIN {
        if (d < 1)        printf "about %.0f hours", (d * 24 < 1 ? 1 : d * 24)
        else if (d < 1.5) printf "about a day"
        else              printf "about %.0f days", d
    }'
}

# plural <count> <singular> <plural>: "1 folder", "3 folders".
plural() {
    if [ "$1" = "1" ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi
}

level_rank() {
    case "$1" in
        critical) printf '3' ;;
        warning)  printf '2' ;;
        notice)   printf '1' ;;
        *)        printf '0' ;;
    esac
}

# path_is_under <path> <dir>: true when path lies strictly inside dir.
path_is_under() {
    if [ "$2" = "/" ]; then [ "$1" != "/" ]; return; fi
    case "$1" in "$2"/*) return 0 ;; esac
    return 1
}

# The mount point of the filesystem holding a path. df answers for paths that
# still exist; otherwise the longest mount point in DISK_ROWS that is the path
# or one of its ancestors.
mount_of_path() {
    local path="$1" row mount best=""
    best=$(df -P -- "$path" 2>/dev/null \
        | awk 'NR == 2 {for (i = 6; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "")}')
    if [ -n "$best" ]; then
        printf '%s' "$best"
        return 0
    fi
    for row in ${DISK_ROWS[@]+"${DISK_ROWS[@]}"}; do
        IFS='|' read -r mount _ <<<"$row"
        if [ "$path" = "$mount" ] || path_is_under "$path" "$mount"; then
            [ ${#mount} -gt ${#best} ] && best="$mount"
        fi
    done
    printf '%s' "$best"
}

# disk_row_field <mount> <field index>: one field of a DISK_ROWS entry
# (1 mount, 2 device, 3 type, 4 size_kb, 5 used_kb, 6 avail_kb, 7 pct).
disk_row_field() {
    local row
    for row in ${DISK_ROWS[@]+"${DISK_ROWS[@]}"}; do
        if [ "${row%%|*}" = "$1" ]; then
            printf '%s' "$row" | cut -d'|' -f"$2"
            return 0
        fi
    done
    return 1
}

# Temporary files and directories removed on exit, however the run ends.
CLEANUP_PATHS=()
cleanup() {
    local path
    for path in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
        rm -rf -- "$path" 2>/dev/null
    done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ME=$(id -un 2>/dev/null || printf 'unknown')

# ---------------------------------------------------------------------------
# System probes
# ---------------------------------------------------------------------------

# The interface carrying the default route, which is what the provider meters.
# Falls back to the first non-loopback interface with traffic.
detect_interface() {
    local iface=""
    if command_exists ip; then
        iface=$(ip route show default 2>/dev/null \
            | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    fi
    if [ -z "$iface" ] && [ -r /proc/net/dev ]; then
        iface=$(awk 'NR > 2 {gsub(/:/, "", $1); if ($1 != "lo" && $2 > 0) {print $1; exit}}' \
            /proc/net/dev)
    fi
    printf '%s' "$iface"
}

# Byte counters since boot for one interface: "<rx> <tx>".
interface_counters() {
    local iface="$1"
    if [ -z "$iface" ] || [ ! -r /proc/net/dev ]; then return 1; fi
    awk -v want="${iface}:" '$1 == want {print $2, $10; found = 1} END {exit !found}' \
        /proc/net/dev
}

get_cpu_usage_percent() {
    local -a s1 s2
    local total1 total2 idle1 idle2 total_delta idle_delta

    [ -r /proc/stat ] || { printf '0.0'; return; }

    # shellcheck disable=SC2034
    read -r _ 's1[0]' 's1[1]' 's1[2]' 's1[3]' 's1[4]' 's1[5]' 's1[6]' 's1[7]' 's1[8]' 's1[9]' < /proc/stat
    sleep 1
    read -r _ 's2[0]' 's2[1]' 's2[2]' 's2[3]' 's2[4]' 's2[5]' 's2[6]' 's2[7]' 's2[8]' 's2[9]' < /proc/stat

    total1=0; total2=0
    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
        total1=$((total1 + ${s1[i]:-0}))
        total2=$((total2 + ${s2[i]:-0}))
    done
    idle1=$(( ${s1[3]:-0} + ${s1[4]:-0} ))
    idle2=$(( ${s2[3]:-0} + ${s2[4]:-0} ))

    total_delta=$((total2 - total1))
    idle_delta=$((idle2 - idle1))

    if [ "$total_delta" -le 0 ]; then printf '0.0'; return; fi
    awk -v t="$total_delta" -v i="$idle_delta" 'BEGIN {printf "%.1f", ((t - i) / t) * 100}'
}

# ---------------------------------------------------------------------------
# Monthly bandwidth collection
# ---------------------------------------------------------------------------
# Three sources, best first:
#   1. vnstat  - purpose-built, survives reboots, exact monthly totals
#   2. Munin RRD via rrdtool - accurate when rrdtool integrates the rate itself
#   3. /proc/net/dev - since-boot counters only; cannot answer "this month"

month_start_epoch() { date -d "$(date +%Y-%m-01)" +%s 2>/dev/null; }
days_in_month()     { date -d "$(date +%Y-%m-01) +1 month -1 day" +%d 2>/dev/null; }

# --- vnstat ----------------------------------------------------------------
vnstat_monthly() {
    command_exists vnstat || return 1
    local iface="$1" out rx tx
    local -a ifarg=()
    [ -n "$iface" ] && ifarg=(-i "$iface")

    if command_exists jq; then
        out=$(vnstat --json m ${ifarg[@]+"${ifarg[@]}"} 2>/dev/null) || return 1
        read -r rx tx < <(printf '%s' "$out" | jq -r '
            .interfaces[0].traffic.month // .interfaces[0].traffic.months // []
            | last // empty
            | "\(.rx) \(.tx)"' 2>/dev/null)
    else
        # --oneline is a stable, documented CSV; with "b" the totals are bytes.
        # Fields 9 and 10 are the current month's rx and tx; 13 to 15 are the
        # all-time totals, which must not be taken for the month.
        out=$(vnstat --oneline b ${ifarg[@]+"${ifarg[@]}"} 2>/dev/null) || return 1
        rx=$(printf '%s' "$out" | awk -F';' '{print $9}')
        tx=$(printf '%s' "$out" | awk -F';' '{print $10}')
    fi

    if ! is_number "${rx:-}" || ! is_number "${tx:-}"; then return 1; fi
    printf '%.0f %.0f' "$rx" "$tx"
}

# --- Munin RRD -------------------------------------------------------------
# Locate the if_<iface>-{up,down}-d.rrd pair. The old hardcoded
# "localhost.localdomain-if_eth0-*" path silently failed on any host whose
# Munin node name or interface differed, dropping the report to since-boot data.
find_munin_rrd() {
    local direction="$1" iface="$2" candidate
    local -a matches=()

    if [ -n "$iface" ]; then
        for candidate in "$MUNIN_RRD_DIR"/*/*-if_"$iface"-"$direction"-d.rrd; do
            [ -f "$candidate" ] && matches+=("$candidate")
        done
    fi
    if [ ${#matches[@]} -eq 0 ]; then
        for candidate in "$MUNIN_RRD_DIR"/*/*-if_*-"$direction"-d.rrd; do
            [ -f "$candidate" ] || continue
            # Skip the if_err_* plugin, which tracks errors rather than volume.
            case "$candidate" in *-if_err_*) continue ;; esac
            matches+=("$candidate")
        done
    fi
    [ ${#matches[@]} -gt 0 ] || return 1

    # Most recently updated wins when several interfaces are graphed.
    local newest=""
    for candidate in "${matches[@]}"; do
        if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
            newest="$candidate"
        fi
    done
    [ -n "$newest" ] || return 1
    printf '%s' "$newest"
}

# Total bytes transferred over a window, integrated by rrdtool itself.
#
# The previous implementation summed `rrdtool fetch` rows and multiplied by the
# RRD's *base* step. rrdtool serves a month-long window from a consolidated
# archive whose rows span pdp_per_row * step seconds, so that under-counted by
# exactly that factor (24x on a stock Munin if_ RRD, and the factor changes as
# the month grows). VDEF TOTAL does rate-to-volume integration correctly.
rrd_total_bytes() {
    local rrd="$1" start="$2" end="$3" ds result

    if ! command_exists rrdtool || [ ! -f "$rrd" ]; then printf '0'; return; fi

    ds=$(rrdtool info "$rrd" 2>/dev/null \
        | sed -n 's/^ds\[\([^]]*\)\]\.index.*/\1/p' | head -1)
    ds="${ds:-42}"

    result=$(rrdtool graph /dev/null --start "$start" --end "$end" \
        "DEF:rate=$rrd:$ds:AVERAGE" "VDEF:total=rate,TOTAL" \
        "PRINT:total:%.0lf" 2>/dev/null \
        | awk '/^-?[0-9]+$/ {print; exit}')

    if is_number "${result:-}" && [ "${result%.*}" -ge 0 ] 2>/dev/null; then
        printf '%s' "$result"
    else
        printf '0'
    fi
}

munin_monthly() {
    local iface="$1" start rx tx up down
    command_exists rrdtool || return 1

    up="${MUNIN_RRD_UP:-$(find_munin_rrd up "$iface")}"
    down="${MUNIN_RRD_DOWN:-$(find_munin_rrd down "$iface")}"
    if [ ! -f "${up:-}" ] || [ ! -f "${down:-}" ]; then return 1; fi

    start=$(month_start_epoch) || return 1
    tx=$(rrd_total_bytes "$up" "$start" now)
    rx=$(rrd_total_bytes "$down" "$start" now)

    # Both zero means Munin has no data for this month - not a usable answer.
    [ "$tx" != "0" ] || [ "$rx" != "0" ] || return 1
    MUNIN_RRD_UP="$up"
    MUNIN_RRD_DOWN="$down"
    printf '%s %s' "$rx" "$tx"
}

# --- Collection ------------------------------------------------------------
NET_SOURCE="none"
NET_IFACE=""
NET_RX=""        # month-to-date, bytes
NET_TX=""
NET_COUNTED=""   # the figure metered against the cap
NET_PCT=""
NET_PROJECTED=""
NET_PROJECTED_PCT=""
NET_BOOT_RX=""
NET_BOOT_TX=""
NET_LIMIT_BYTES=""

counted_bytes() {
    local rx="$1" tx="$2"
    case "$BANDWIDTH_COUNT_MODE" in
        in)  printf '%s' "$rx" ;;
        sum) awk -v r="$rx" -v t="$tx" 'BEGIN {printf "%.0f", r + t}' ;;
        max) awk -v r="$rx" -v t="$tx" 'BEGIN {printf "%.0f", (r > t ? r : t)}' ;;
        *)   printf '%s' "$tx" ;;
    esac
}

collect_network() {
    local pair elapsed_days month_days

    NET_IFACE="${NET_INTERFACE:-$(detect_interface)}"

    if pair=$(vnstat_monthly "$NET_IFACE"); then
        NET_SOURCE="vnstat"
    elif pair=$(munin_monthly "$NET_IFACE"); then
        NET_SOURCE="munin-rrd"
    else
        NET_SOURCE="proc"
        pair=""
    fi

    if [ -n "$pair" ]; then
        read -r NET_RX NET_TX <<<"$pair"
        NET_COUNTED=$(counted_bytes "$NET_RX" "$NET_TX")
        NET_LIMIT_BYTES=$(awk -v tb="$BANDWIDTH_LIMIT_TB" -v f="$BYTES_PER_TIB" \
            'BEGIN {printf "%.0f", tb * f}')
        NET_PCT=$(awk -v u="$NET_COUNTED" -v l="$NET_LIMIT_BYTES" \
            'BEGIN {if (l > 0) printf "%.2f", (u / l) * 100; else print "0.00"}')

        # Straight-line projection to the end of the month.
        month_days=$(days_in_month)
        elapsed_days=$(awk -v now="$(date +%s)" -v start="$(month_start_epoch)" \
            'BEGIN {d = (now - start) / 86400; printf "%.4f", (d > 0.02 ? d : 0.02)}')
        if is_number "${month_days:-}" && is_number "$elapsed_days"; then
            NET_PROJECTED=$(awk -v u="$NET_COUNTED" -v e="$elapsed_days" -v m="$month_days" \
                'BEGIN {printf "%.0f", u / e * m}')
            NET_PROJECTED_PCT=$(awk -v p="$NET_PROJECTED" -v l="$NET_LIMIT_BYTES" \
                'BEGIN {if (l > 0) printf "%.2f", (p / l) * 100; else print "0.00"}')
        fi

        if compare_gt "$NET_PCT" "$BANDWIDTH_WARN_PCT"; then
            record_issue warning \
                "Outbound bandwidth at ${NET_PCT}% of the ${BANDWIDTH_LIMIT_TB}TB monthly cap" \
                bandwidth
        else
            if compare_gt "$NET_PCT" "$BANDWIDTH_NOTICE_PCT"; then
                record_issue notice \
                    "Over ${BANDWIDTH_NOTICE_PCT}% of the monthly bandwidth cap used" bandwidth
            fi
            # Tested on its own: between the notice and the warning thresholds a
            # month heading past the cap still deserves the warning it gets below
            # the notice threshold.
            if compare_gt "${NET_PROJECTED_PCT:-0}" "100"; then
                record_issue warning \
                    "Projected to exceed the monthly cap (${NET_PROJECTED_PCT}% by month end)" \
                    bandwidth-projection
            fi
        fi
    else
        record_issue notice \
            "No month-to-date bandwidth source (install vnstat for cap tracking)" \
            bandwidth-source
    fi

    if pair=$(interface_counters "$NET_IFACE"); then
        read -r NET_BOOT_RX NET_BOOT_TX <<<"$pair"
    fi
}

# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------
MEM_TOTAL_KB="" MEM_USED_KB="" MEM_AVAIL_KB="" MEM_PCT=""
SWAP_TOTAL_KB="" SWAP_USED_KB="" SWAP_PCT=""

collect_memory() {
    [ -r /proc/meminfo ] || return 0

    local total avail free buffers cached swaptotal swapfree
    read -r total avail free buffers cached swaptotal swapfree < <(
        awk '/^MemTotal:/     {total = $2}
             /^MemAvailable:/ {avail = $2; have_avail = 1}
             /^MemFree:/      {free = $2}
             /^Buffers:/      {buffers = $2}
             /^Cached:/       {cached = $2}
             /^SwapTotal:/    {swaptotal = $2}
             /^SwapFree:/     {swapfree = $2}
             END {print total + 0, (have_avail ? avail : -1), free + 0, \
                        buffers + 0, cached + 0, swaptotal + 0, swapfree + 0}' \
            /proc/meminfo
    )

    MEM_TOTAL_KB="$total"
    [ "${MEM_TOTAL_KB:-0}" -gt 0 ] 2>/dev/null || return 0

    if [ "${avail:-(-1)}" -ge 0 ] 2>/dev/null; then
        MEM_AVAIL_KB="$avail"
    else
        MEM_AVAIL_KB=$((free + buffers + cached))
    fi
    MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
    MEM_PCT=$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" \
        'BEGIN {printf "%.1f", (u / t) * 100}')

    if compare_gt "$MEM_PCT" "$MEMORY_WARN_PCT"; then
        record_issue warning "Memory usage at ${MEM_PCT}%" memory
    elif compare_gt "$MEM_PCT" "$MEMORY_NOTICE_PCT"; then
        record_issue notice "Memory usage above ${MEMORY_NOTICE_PCT}% (${MEM_PCT}%)" memory
    fi

    if [ "${swaptotal:-0}" -gt 0 ] 2>/dev/null; then
        SWAP_TOTAL_KB="$swaptotal"
        SWAP_USED_KB=$((swaptotal - swapfree))
        SWAP_PCT=$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL_KB" \
            'BEGIN {printf "%.1f", (u / t) * 100}')
        if compare_gt "$SWAP_PCT" "$SWAP_WARN_PCT"; then
            record_issue warning "Swap usage at ${SWAP_PCT}%" swap
        elif compare_gt "$SWAP_PCT" "$SWAP_NOTICE_PCT"; then
            record_issue notice "Swap usage above ${SWAP_NOTICE_PCT}% (${SWAP_PCT}%)" swap
        fi
    fi
}

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
LOAD_1="" LOAD_5="" LOAD_15="" CPU_CORES="" LOAD_PCT="" CPU_USAGE=""

collect_load() {
    [ -r /proc/loadavg ] || return 0
    read -r LOAD_1 LOAD_5 LOAD_15 _ < /proc/loadavg

    if command_exists nproc; then
        CPU_CORES=$(nproc 2>/dev/null)
    elif [ -r /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo)
    fi
    [ "${CPU_CORES:-0}" -gt 0 ] 2>/dev/null || CPU_CORES=1

    LOAD_PCT=$(awk -v l="$LOAD_1" -v c="$CPU_CORES" 'BEGIN {printf "%.1f", (l / c) * 100}')
    CPU_USAGE=$(get_cpu_usage_percent)

    local warn_threshold
    warn_threshold=$(awk -v c="$CPU_CORES" -v m="$LOAD_WARN_MULTIPLIER" \
        'BEGIN {printf "%.2f", c * m}')
    if compare_gt "$LOAD_1" "$warn_threshold"; then
        record_issue warning \
            "Load average ${LOAD_1} exceeds ${warn_threshold} (${CPU_CORES} cores)" load
    elif compare_gt "$LOAD_PCT" "$LOAD_NOTICE_PCT"; then
        record_issue notice "Load at ${LOAD_PCT}% of capacity" load
    fi
}

# ---------------------------------------------------------------------------
# Disk and inodes
# ---------------------------------------------------------------------------
# Rows are "mount|filesystem|type|size_kb|used_kb|avail_kb|use_pct|level".
DISK_ROWS=()
INODE_ROWS=()     # the filesystems whose inode use is high, for the disk section
INODE_ALL=()      # "mount|pct|level" for every filesystem that counts inodes

collect_disk() {
    command_exists df || return 0
    local fs type size used avail pct mount level

    # Process substitution rather than a pipe: a piped `while` runs in a
    # subshell, so recorded issues and the overall status would be discarded.
    while read -r fs type size used avail pct mount; do
        [ -n "${mount:-}" ] || continue
        is_ignored_fs_type "$type" && continue

        pct="${pct%\%}"
        level="ok"
        # df prints "-" for filesystems that do not report usage (some NFS,
        # ZFS and autofs mounts); a bare [ -gt ] on that is a runtime error.
        if is_number "$pct"; then
            if compare_gt "$pct" "$DISK_CRITICAL_PCT"; then
                level="critical"
                record_issue critical "$mount is ${pct}% full" "disk-full:$mount"
            elif compare_gt "$pct" "$DISK_WARN_PCT"; then
                level="warning"
                record_issue warning "$mount is ${pct}% full" "disk-full:$mount"
            elif compare_gt "$pct" "$DISK_NOTICE_PCT"; then
                level="notice"
                record_issue notice "$mount is ${pct}% full" "disk-full:$mount"
            fi
        else
            pct=""
        fi
        DISK_ROWS+=("$mount|$fs|$type|$size|$used|$avail|$pct|$level")
    done < <(df -PTk 2>/dev/null | tail -n +2)

    while read -r _ type inodes iused ifree pct mount; do
        [ -n "${mount:-}" ] || continue
        is_ignored_fs_type "$type" && continue
        pct="${pct%\%}"
        is_number "$pct" || continue
        level="ok"
        if compare_gt "$pct" "$INODE_WARN_PCT"; then
            level="warning"
            record_issue warning "$mount inode usage at ${pct}%" "inodes:$mount"
        elif compare_gt "$pct" "$INODE_NOTICE_PCT"; then
            level="notice"
            record_issue notice "$mount inode usage at ${pct}%" "inodes:$mount"
        fi
        INODE_ALL+=("$mount|$pct|$level")
        [ "$level" = "ok" ] && continue
        INODE_ROWS+=("$mount|$inodes|$iused|$ifree|$pct|$level")
    done < <(df -PTi 2>/dev/null | tail -n +2)
}

# ---------------------------------------------------------------------------
# System health
# ---------------------------------------------------------------------------
MUNIN_CRITICAL="" MUNIN_WARNING="" MUNIN_UNKNOWN=""
SERVICES_OK="" SERVICES_TOTAL="" SERVICES_DOWN=() SERVICES_CHECKED=()
FAILED_UNITS="" FAILED_UNIT_NAMES=() IGNORED_UNIT_NAMES=()
REBOOT_REQUIRED="unknown"
UPDATES_TOTAL="" UPDATES_SECURITY=""

collect_munin_problems() {
    if ! command_exists w3m || [ ! -f "$MUNIN_WWW_DIR/problems.html" ]; then
        return 1
    fi
    local data
    data=$(w3m -dump "$MUNIN_WWW_DIR/problems.html" 2>/dev/null) || return 1

    MUNIN_CRITICAL=$(printf '%s' "$data" | grep -oE 'Critical \([0-9]+\)' | grep -oE '[0-9]+' | head -1)
    MUNIN_WARNING=$(printf '%s' "$data" | grep -oE 'Warning \([0-9]+\)' | grep -oE '[0-9]+' | head -1)
    MUNIN_UNKNOWN=$(printf '%s' "$data" | grep -oE 'Unknown \([0-9]+\)' | grep -oE '[0-9]+' | head -1)
    MUNIN_CRITICAL="${MUNIN_CRITICAL:-0}"
    MUNIN_WARNING="${MUNIN_WARNING:-0}"
    MUNIN_UNKNOWN="${MUNIN_UNKNOWN:-0}"

    if [ "$MUNIN_CRITICAL" -gt 0 ]; then
        record_issue critical "Munin reports ${MUNIN_CRITICAL} critical plugin state(s)" munin
    elif [ "$MUNIN_WARNING" -gt 0 ]; then
        record_issue warning "Munin reports ${MUNIN_WARNING} warning plugin state(s)" munin
    fi
    return 0
}

collect_services() {
    SERVICES_OK=0
    SERVICES_TOTAL=0
    local group primary alt name
    for group in "ssh:sshd" "cron:crond"; do
        IFS=':' read -r primary alt <<<"$group"
        name=""
        if service_exists "$primary"; then name="$primary"
        elif service_exists "$alt"; then name="$alt"
        fi
        [ -n "$name" ] || continue

        SERVICES_CHECKED+=("$name")
        SERVICES_TOTAL=$((SERVICES_TOTAL + 1))
        if service_is_active "$name"; then
            SERVICES_OK=$((SERVICES_OK + 1))
        else
            SERVICES_DOWN+=("$name")
            record_issue warning "Service $name is not running" "service:$name"
        fi
    done
}

# True when the unit is named in IGNORE_FAILED_UNITS: unit names or shell
# patterns (cloud-init-*.service), separated by spaces or commas.
unit_is_ignored() {
    local unit="$1" pattern
    local -a patterns=()
    # read does not expand globs, so a pattern such as * reaches the test intact.
    read -r -a patterns <<<"${IGNORE_FAILED_UNITS//,/ }"
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
        # The unquoted right-hand side is deliberate: it is a pattern.
        # shellcheck disable=SC2053
        [[ $unit == $pattern ]] && return 0
    done
    return 1
}

collect_failed_units() {
    if [ "$CHECK_FAILED_UNITS" != "1" ] || ! command_exists systemctl; then return 0; fi
    local names name
    names=$(systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -v '^$') || true
    FAILED_UNITS=0 FAILED_UNIT_NAMES=() IGNORED_UNIT_NAMES=()
    if [ -n "$names" ]; then
        while read -r name; do
            if unit_is_ignored "$name"; then
                IGNORED_UNIT_NAMES+=("$name")
            else
                FAILED_UNIT_NAMES+=("$name")
            fi
        done <<<"$names"
        FAILED_UNITS=${#FAILED_UNIT_NAMES[@]}
    fi
    if [ "$FAILED_UNITS" -gt 0 ]; then
        # The unit names belong in the key: a second unit failing is news.
        record_issue warning "${FAILED_UNITS} failed systemd unit(s): ${FAILED_UNIT_NAMES[*]}" \
            "failed-units:$(printf '%s\n' "${FAILED_UNIT_NAMES[@]}" | sort | paste -sd, -)"
    fi
}

collect_reboot_required() {
    [ "$CHECK_REBOOT_REQUIRED" = "1" ] || return 0
    if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
        REBOOT_REQUIRED="yes"
        record_issue notice "A reboot is required to finish applying updates" reboot
    else
        REBOOT_REQUIRED="no"
    fi
}

collect_updates() {
    [ "$CHECK_UPDATES" = "1" ] || return 0
    local out
    if [ -x /usr/lib/update-notifier/apt-check ]; then
        out=$(/usr/lib/update-notifier/apt-check 2>&1) || return 0
        UPDATES_TOTAL=${out%%;*}
        UPDATES_SECURITY=${out##*;}
    elif [ -r /var/lib/update-notifier/updates-available ]; then
        UPDATES_TOTAL=$(awk '/[0-9]+ update/ {print $1; exit}' \
            /var/lib/update-notifier/updates-available)
    else
        return 0
    fi

    is_number "${UPDATES_SECURITY:-}" || UPDATES_SECURITY=""
    is_number "${UPDATES_TOTAL:-}"    || UPDATES_TOTAL=""
    if [ -n "$UPDATES_SECURITY" ] && [ "$UPDATES_SECURITY" -gt 0 ]; then
        record_issue warning "${UPDATES_SECURITY} security update(s) pending" security-updates
    fi
}

TOP_MEM_ROWS=()
TOP_CPU_ROWS=()
collect_top_processes() {
    if [ "$SHOW_TOP_PROCESSES" != "1" ] || ! command_exists ps; then return 0; fi
    is_number "$TOP_PROCESS_COUNT" || TOP_PROCESS_COUNT=3

    # Exclude our own `ps` invocation: it always measures itself busy and would
    # otherwise take the top CPU slot on an idle machine.
    mapfile -t TOP_MEM_ROWS < <(
        ps -eo pmem=,pcpu=,comm= --sort=-pmem 2>/dev/null \
            | awk '$3 != "ps"' | head -n "$TOP_PROCESS_COUNT"
    )
    mapfile -t TOP_CPU_ROWS < <(
        ps -eo pmem=,pcpu=,comm= --sort=-pcpu 2>/dev/null \
            | awk '$3 != "ps"' | head -n "$TOP_PROCESS_COUNT"
    )
}

# ---------------------------------------------------------------------------
# State directory
# ---------------------------------------------------------------------------
# The disk history, the cached folder scan and the notification memory live
# here. The default follows the effective user rather than $HOME: under
# `sudo -E` HOME still names the invoking user, and root-owned files would end
# up in that user's home. State files are read as data and never sourced.
STATE_OK=0

state_init() {
    if [ -z "$STATE_DIR" ]; then
        if [ "$EUID" -eq 0 ]; then
            STATE_DIR="/var/lib/vpsusagecheck"
        else
            STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vpsusagecheck"
        fi
    fi
    STATE_OK=0
    if [ ! -d "$STATE_DIR" ]; then
        (umask 077 && mkdir -p -- "$STATE_DIR") 2>/dev/null || return 0
    fi
    if [ -w "$STATE_DIR" ] && [ -x "$STATE_DIR" ]; then STATE_OK=1; fi
    return 0
}

# with_lock <lock name> <seconds to wait | -n> <command...>
#
# Runs the command (usually a function, so that the variables it sets survive)
# while holding an exclusive flock on STATE_DIR/<lock name>. Returns 75 when
# the lock stays busy. Without flock, or without a state directory, the command
# simply runs: a cron run and a manual run overlapping is rare, and the worst
# outcome is a duplicated history sample.
with_lock() {
    local name="$1" wait="$2" fd rc
    shift 2
    if [ "$STATE_OK" -ne 1 ] || ! command_exists flock; then
        "$@"
        return
    fi
    if ! exec {fd}>>"$STATE_DIR/$name"; then
        "$@"
        return
    fi
    if [ "$wait" = "-n" ]; then
        flock -n "$fd" || { exec {fd}>&-; return 75; }
    else
        flock -w "$wait" "$fd" || { exec {fd}>&-; return 75; }
    fi
    LOCK_FDS+=("$fd")
    "$@"
    rc=$?
    unset 'LOCK_FDS[${#LOCK_FDS[@]}-1]'
    exec {fd}>&-
    return "$rc"
}

# without_locks <command...>: runs an outside program with the lock descriptors
# closed. A notifier that leaves a daemon behind would otherwise hold the lock
# for as long as the daemon lives, and every later run would wait for it.
LOCK_FDS=()
without_locks() {
    (
        for fd in ${LOCK_FDS[@]+"${LOCK_FDS[@]}"}; do exec {fd}>&-; done
        "$@"
    )
}

# atomic_replace <file>: writes stdin to a temporary file beside <file>, then
# renames it over <file>, so a reader never sees a half-written state file.
atomic_replace() {
    local target="$1" tmp
    tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || return 1
    if cat > "$tmp" && mv -f -- "$tmp" "$target"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# ---------------------------------------------------------------------------
# Disk forecast
# ---------------------------------------------------------------------------
# Every run appends one sample per real filesystem to history.tsv:
#
#   epoch <TAB> size_kb <TAB> used_kb <TAB> avail_kb <TAB> mount
#
# The forecast fits a least-squares line to the absolute used_kb. Munin's df
# plugin keeps percentages only, which a resize turns into a sudden drop (a
# 72 GB disk enlarged to 145 GB falls from 84% to 42% overnight while nothing
# was deleted); the bytes in use are unaffected by a resize.
readonly HISTORY_MIN_INTERVAL=600
readonly HISTORY_KEEP_DAYS=60
readonly TREND_MIN_SPAN_HOURS=12
readonly TREND_MIN_GROWTH_KB=262144     # 256 MB over the window before alerting

# mount|state|slope_kb_day|pace_kb_day|days_to_full|samples|span_h|level
# state: collecting | growing | steady | shrinking
TREND_ROWS=()

disk_history_append() {
    local hist="$STATE_DIR/history.tsv" now last first row mount size used avail
    now=$(date +%s)
    last=0
    if [ -s "$hist" ]; then
        last=$(awk -F'\t' 'END {printf "%.0f", $1}' "$hist")
        is_number "$last" || last=0
    fi
    if [ $((now - last)) -ge "$HISTORY_MIN_INTERVAL" ]; then
        for row in ${DISK_ROWS[@]+"${DISK_ROWS[@]}"}; do
            IFS='|' read -r mount _ _ size used avail _ _ <<<"$row"
            if is_number "$size" && is_number "$used" && is_number "$avail"; then
                printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$size" "$used" "$avail" "$mount"
            fi
        done >> "$hist"
    fi

    # Pruning rewrites the file, so do it only once the oldest sample is a day
    # past the retention period, i.e. about once a day.
    first=$(awk -F'\t' 'NR == 1 {printf "%.0f", $1; exit}' "$hist" 2>/dev/null)
    if is_number "$first" && [ $((now - first)) -gt $(((HISTORY_KEEP_DAYS + 1) * 86400)) ]; then
        awk -F'\t' -v cut=$((now - HISTORY_KEEP_DAYS * 86400)) '$1 >= cut' "$hist" \
            | atomic_replace "$hist"
    fi
    return 0
}

# Fits the trend of one mount. Prints one of
#   none
#   collecting <samples> <span_hours>
#   ok <samples> <span_hours> <slope_kb_per_day> <growth_kb_in_window> <pace_kb_per_day|->
disk_trend_fit() {
    awk -F'\t' -v m="$1" -v win="$DISK_TREND_DAYS" -v minspan="$TREND_MIN_SPAN_HOURS" '
        $5 == m { n++; t[n] = $1; u[n] = $3 }
        END {
            if (n == 0) { print "none"; exit }
            # The samples inside the window that ends at the newest one.
            k = 0
            for (i = 1; i <= n; i++)
                if (t[i] >= t[n] - win * 86400) { k++; tt[k] = t[i]; uu[k] = u[i] }
            span = (tt[k] - tt[1]) / 3600
            if (k < 3 || span < minspan) { printf "collecting %d %.1f\n", k, span; exit }

            # Time in days from the first sample. Raw epochs squared (about
            # 3e18) exceed the 2^53 of a double, and the normal equations would
            # cancel to noise.
            for (i = 1; i <= k; i++) {
                x = (tt[i] - tt[1]) / 86400
                sx += x; sy += uu[i]; sxx += x * x; sxy += x * uu[i]
            }
            d = k * sxx - sx * sx
            slope = (d > 0) ? (k * sxy - sx * sy) / d : 0

            # The pace of the last day: the sample nearest to 24 h before the
            # newest one, accepted between 18 h and 36 h.
            best = 0; bestgap = 0
            for (i = 1; i < k; i++) {
                age = tt[k] - tt[i]
                if (age < 64800 || age > 129600) continue
                gap = age - 86400; if (gap < 0) gap = -gap
                if (!best || gap < bestgap) { best = i; bestgap = gap }
            }
            pace = "-"
            if (best) pace = sprintf("%.0f", (uu[k] - uu[best]) / ((tt[k] - tt[best]) / 86400))
            printf "ok %d %.1f %.0f %.0f %s\n", k, span, slope, uu[k] - uu[1], pace
        }' "$STATE_DIR/history.tsv"
}

collect_disk_forecast() {
    [ "$STATE_OK" -eq 1 ] || return 0
    with_lock state.lock 10 disk_history_append
    [ -s "$STATE_DIR/history.tsv" ] || return 0

    local row mount avail fit state n span slope grown pace days level pace_days
    for row in ${DISK_ROWS[@]+"${DISK_ROWS[@]}"}; do
        IFS='|' read -r mount _ _ _ _ avail _ _ <<<"$row"
        is_number "$avail" || continue
        fit=$(disk_trend_fit "$mount")
        state="" n="" span="" slope="" grown="" pace=""
        read -r state n span slope grown pace <<<"$fit"
        case "$state" in
            ok) ;;
            collecting)
                TREND_ROWS+=("$mount|collecting||||$n|$span|ok")
                continue
                ;;
            *) continue ;;
        esac

        level="ok"
        days=""
        if compare_gt "$slope" 0 && ! compare_gt "$TREND_MIN_GROWTH_KB" "$grown"; then
            state="growing"
            days=$(awk -v a="$avail" -v s="$slope" 'BEGIN {printf "%.1f", a / s}')
            if compare_gt "$DISK_FILL_CRITICAL_DAYS" "$days"; then level="critical"
            elif compare_gt "$DISK_FILL_WARN_DAYS" "$days"; then level="warning"
            elif compare_gt "$DISK_FILL_NOTICE_DAYS" "$days"; then level="notice"
            fi
            if [ "$level" != "ok" ]; then
                record_issue "$level" \
                    "Disk $mount will be full in $(days_phrase "$days") at the pace of the last ${DISK_TREND_DAYS} days ($(signed_kb_to_human "$slope") a day)" \
                    "disk-fill:$mount"
            fi
        elif compare_gt "$slope" 0; then
            state="steady"
        else
            state="shrinking"
        fi

        # A sudden burst. On its own it can only raise the short-fuse alert, so
        # one large download is not reported as a trend.
        if [ "$pace" != "-" ] && ! compare_gt "$TREND_MIN_GROWTH_KB" "$pace"; then
            pace_days=$(awk -v a="$avail" -v p="$pace" 'BEGIN {printf "%.2f", a / p}')
            if compare_gt "$DISK_FILL_CRITICAL_DAYS" "$pace_days" && [ "$level" != "critical" ]; then
                record_issue warning \
                    "Disk $mount grew by $(kb_to_human "$pace") in the last 24 hours; at that pace it is full in $(days_phrase "$pace_days")" \
                    "disk-burst:$mount"
            fi
        fi
        TREND_ROWS+=("$mount|$state|$slope|$pace|$days|$n|$span|$level")
    done
}

# ---------------------------------------------------------------------------
# Folder scan
# ---------------------------------------------------------------------------
# The scan is the one expensive part of the report (a couple of minutes for a
# million inodes on a cold cache), so its result is cached in scan.tsv and
# refreshed at most every DISK_SCAN_MAX_AGE_HOURS. Records are TAB-separated
# and typed by their first field, because display commands may contain '|';
# no field is ever empty ("-" stands for nothing):
#
#   M  key  value                                        metadata
#   D  kb  depth  path                                   directory sizes (du)
#   F  kb  mtime  nlink  big|log  path                   large files and logs
#   N  path                                              Next.js build caches
#   S  kb  category  safe|review  action  path  command  note    savings
readonly SCAN_FORMAT=1
readonly SCAN_DIR_MIN_KB=16384
readonly LOG_FILE_MIN_MB=200
readonly STALE_FILE_DAYS=180
readonly DELETED_OPEN_NOTICE_KB=512000
# Subdirectories of ~/.cache that only ever hold re-downloadable data.
readonly SAFE_CACHE_DIRS="pip uv pnpm yarn node-gyp go-build"

SCAN_STATUS="none"     # none | complete | partial | failed | disabled
SCAN_FINISHED=""
SCAN_STARTED=""
SCAN_ROOTS=""
SCAN_UNREADABLE=""
SCAN_SKIPPED=0
SCAN_NOTE=""
RECLAIM_MIN_KB=0
DIR_TOP_ROWS=()        # kb <TAB> change_kb|- <TAB> path
GROW_ROWS=()           # change_kb <TAB> path
GROWTH_SINCE=""
BIGFILE_ROWS=()        # kb <TAB> mtime <TAB> path
SAVING_ROWS=()         # kb <TAB> category <TAB> safety <TAB> action <TAB> path <TAB> command <TAB> note
SAVINGS_SAFE_KB=0
SAVINGS_REVIEW_KB=0
COVERAGE_ROWS=()       # mount|scanned_kb|used_kb

same_filesystem() {
    [ "$(stat -c %d -- "$1" 2>/dev/null)" = "$(stat -c %d -- "$2" 2>/dev/null)" ]
}

# The directories to scan, one per line: the places where users, services and
# applications keep data, never the operating system itself. Default roots on
# pseudo filesystems (a tmpfs /tmp) are skipped; roots named in
# DISK_SCAN_ROOTS are always scanned. A root nested in another root on the same
# filesystem is dropped (du -x covers it already); a separately mounted one
# stays, since du -x stops at its mount point.
scan_roots() {
    local -a candidates=() kept=() out=()
    local root row mount type i j nested explicit=0
    if [ -n "$DISK_SCAN_ROOTS" ]; then
        explicit=1
        read -r -a candidates <<<"$DISK_SCAN_ROOTS"
    else
        candidates=(/home /root /srv /opt /var /usr/local /tmp)
        for row in ${DISK_ROWS[@]+"${DISK_ROWS[@]}"}; do
            IFS='|' read -r mount _ <<<"$row"
            case "$mount" in /|/boot|/boot/*) continue ;; esac
            candidates+=("$mount")
        done
    fi
    for root in ${candidates[@]+"${candidates[@]}"}; do
        root=$(readlink -f -- "$root" 2>/dev/null) || continue
        [ -d "$root" ] || continue
        if [ "$explicit" -eq 0 ]; then
            type=$(df -PT -- "$root" 2>/dev/null | awk 'NR == 2 {print $2}')
            [ -n "$type" ] && is_ignored_fs_type "$type" && continue
        fi
        kept+=("$root")
    done
    for i in ${kept[@]+"${!kept[@]}"}; do
        nested=0
        for j in "${!kept[@]}"; do
            [ "$i" = "$j" ] && continue
            if [ "${kept[$j]}" = "${kept[$i]}" ]; then
                [ "$j" -lt "$i" ] && nested=1
            elif path_is_under "${kept[$i]}" "${kept[$j]}" \
                && same_filesystem "${kept[$i]}" "${kept[$j]}"; then
                nested=1
            fi
        done
        [ "$nested" -eq 0 ] && out+=("${kept[$i]}")
    done
    [ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
    return 0
}

# Idle I/O priority, lowest CPU priority, and a hard time limit. ionice is
# probed first because it fails outright where the class is not permitted.
SCAN_PREFIX=()
scan_prefix() {
    SCAN_PREFIX=()
    if command_exists timeout; then
        SCAN_PREFIX+=(timeout --foreground -k 10 "$DISK_SCAN_TIMEOUT")
    fi
    if command_exists ionice && ionice -c3 true 2>/dev/null; then
        SCAN_PREFIX+=(ionice -c3)
    fi
    command_exists nice && SCAN_PREFIX+=(nice -n 19)
    return 0
}

# NUL-terminated records to lines. Newlines inside a path become \001, so the
# record is later recognised (control character) and skipped. An unterminated
# last record, left by a scan that was killed, is dropped.
nul_records() {
    local file="$1"
    [ -s "$file" ] || return 0
    if [ "$(tail -c 1 -- "$file" | od -An -tx1 | tr -d ' \n')" = "00" ]; then
        tr '\n\0' '\001\n' < "$file"
    else
        tr '\n\0' '\001\n' < "$file" | sed '$d'
    fi
}

scan_meta() {
    awk -F'\t' -v k="$2" '$1 == "M" && $2 == k {v = $3} END {print v}' "$1" 2>/dev/null
}

scan_announce() {
    if [ "$QUIET" -eq 0 ] && [ -t 2 ]; then
        printf '%s: scanning folders to see where the space goes (this can take a few minutes; the result is kept for %s h)...\n' \
            "$PROGNAME" "$DISK_SCAN_MAX_AGE_HOURS" >&2
    fi
}

# scan_run <output file>: one du and one find over the scan roots, then the
# savings probes. Writes typed records; the status is in "M status".
scan_run() {
    local dest="$1" work rc frc status unreadable started big_k log_k
    local -a roots=()
    mapfile -t roots < <(scan_roots)
    if [ ${#roots[@]} -eq 0 ]; then
        printf 'M\tstatus\tfailed\nM\tfinished\t%s\n' "$(date +%s)" > "$dest"
        return 1
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/vpsusagecheck.XXXXXX") || return 1
    CLEANUP_PATHS+=("$work")
    scan_prefix
    started=$(date +%s)

    # One du over every root, so a hard-linked file is counted once. Exit 1 only
    # means some directories were unreadable; 124 and 137 mean the time limit.
    "${SCAN_PREFIX[@]}" du -0 -xk -d "$DISK_SCAN_DEPTH" -- "${roots[@]}" \
        > "$work/du" 2> "$work/du.err"
    rc=$?
    case "$rc" in
        0|1)     status="complete" ;;
        124|137) status="partial" ;;
        *)       status="failed" ;;
    esac
    [ -s "$work/du" ] || status="failed"
    unreadable=$(grep -c '^du: cannot' "$work/du.err" 2>/dev/null)
    is_number "$unreadable" || unreadable=0

    if [ "$status" != "failed" ]; then
        big_k=$(awk -v m="$DISK_BIGFILE_MB" 'BEGIN {printf "%.0f", m * 1024 - 1}')
        log_k=$((LOG_FILE_MIN_MB * 1024 - 1))
        "${SCAN_PREFIX[@]}" find "${roots[@]}" -xdev \
            \( -type d -path '*/.next/cache' -printf 'N\t%p\0' -prune \) -o \
            \( -type f -name '*.log' -size +"${log_k}k" -printf 'F\t%k\t%T@\t%n\tlog\t%p\0' \) -o \
            \( -type f -size +"${big_k}k" -printf 'F\t%k\t%T@\t%n\tbig\t%p\0' \) \
            > "$work/find" 2>/dev/null
        frc=$?
        if [ "$frc" -eq 124 ] || [ "$frc" -eq 137 ]; then status="partial"; fi
    fi

    {
        printf 'M\tformat\t%s\n' "$SCAN_FORMAT"
        printf 'M\tstarted\t%s\n' "$started"
        printf 'M\tstatus\t%s\n' "$status"
        printf 'M\troots\t%s\n' "${roots[*]}"
        printf 'M\tunreadable\t%s\n' "$unreadable"
        printf 'M\teuid\t%s\n' "$EUID"
        nul_records "$work/du" | awk -F'\t' -v min="$SCAN_DIR_MIN_KB" '
            NF != 2 || $2 ~ /[[:cntrl:]]/ { skipped++; next }
            $1 + 0 >= min {
                depth = ($2 == "/") ? 0 : split($2, parts, "/") - 1
                print "D\t" $1 "\t" depth "\t" $2
            }
            END { print "M\tskipped\t" skipped + 0 }'
        nul_records "$work/find" | awk -F'\t' '
            ($1 == "N" && NF == 2 && $2 !~ /[[:cntrl:]]/) { print; next }
            ($1 == "F" && NF == 6 && $6 !~ /[[:cntrl:]]/) {
                sub(/\..*/, "", $3)
                print "F\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
                next
            }
            { skipped++ }
            END { print "M\tskipped\t" skipped + 0 }'
    } > "$dest"

    scan_savings "$dest" > "$work/savings"
    cat "$work/savings" >> "$dest"
    printf 'M\tfinished\t%s\n' "$(date +%s)" >> "$dest"
    rm -rf -- "$work"
    [ "$status" != "failed" ]
}

# Keeps the directory sizes of one scan per day for the growth comparison.
scan_snapshot() {
    local cache="$STATE_DIR/scan.tsv" f day cutoff keep
    awk -F'\t' '$1 == "D" || ($1 == "M" && $2 == "finished")' "$cache" \
        | atomic_replace "$STATE_DIR/dirs-$(date +%Y%m%d).tsv"
    keep=$(awk -v d="$DISK_TREND_DAYS" 'BEGIN {printf "%.0f", d + 1}')
    cutoff=$(date -d "-$keep days" +%Y%m%d 2>/dev/null) || return 0
    for f in "$STATE_DIR"/dirs-*.tsv; do
        [ -f "$f" ] || continue
        day=${f##*/dirs-}
        day=${day%.tsv}
        case "$day" in *[!0-9]*) continue ;; esac
        [ "$day" -lt "$cutoff" ] && rm -f -- "$f"
    done
    return 0
}

# The oldest daily snapshot that is at least one day and at most
# DISK_TREND_DAYS days old, or nothing.
growth_snapshot() {
    local today oldest f day days
    days=$(awk -v d="$DISK_TREND_DAYS" 'BEGIN {printf "%.0f", d}')
    today=$(date +%Y%m%d)
    oldest=$(date -d "-$days days" +%Y%m%d 2>/dev/null) || return 0
    for f in "$STATE_DIR"/dirs-*.tsv; do
        [ -f "$f" ] || continue
        day=${f##*/dirs-}
        day=${day%.tsv}
        case "$day" in *[!0-9]*) continue ;; esac
        if [ "$day" -lt "$today" ] && [ "$day" -ge "$oldest" ]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 0
}

scan_refresh() {
    local cache="$STATE_DIR/scan.tsv" tmp status
    tmp=$(mktemp "$cache.XXXXXX") || return 1
    CLEANUP_PATHS+=("$tmp")
    scan_announce
    scan_run "$tmp"
    status=$(scan_meta "$tmp" status)
    if [ "$status" = "complete" ] || { [ "$status" = "partial" ] && [ ! -s "$cache" ]; }; then
        mv -f -- "$tmp" "$cache"
    else
        rm -f -- "$tmp"
    fi
    case "$status" in
        complete)
            rm -f -- "$STATE_DIR/scan.partial"
            scan_snapshot
            ;;
        partial)
            date +%s > "$STATE_DIR/scan.partial"
            ;;
        *)
            SCAN_NOTE="The folder scan failed; showing the previous result, if any."
            ;;
    esac
    return 0
}

# select_dirs <min> <count>: reads "value <TAB> depth <TAB> path" and prints the
# "value <TAB> path" lines worth showing, largest first.
#
# Walking from the deepest entries up, a directory is shown when its value
# reaches <min> and less than half of it is already accounted for by shown
# directories below it; what is accounted for passes on to the parent. The list
# therefore names ~/.local/share/pnpm rather than /home, /home/user, ~/.local and
# ~/.local/share as well, while a parent whose bulk is spread over many small
# folders still appears. Buckets by depth keep it to POSIX awk (no asort).
select_dirs() {
    awk -F'\t' -v min="$1" '
        {
            value[$3] = $1 + 0
            depth = $2 + 0
            if (depth > maxdepth) maxdepth = depth
            bucket[depth] = bucket[depth] SUBSEP $3
        }
        END {
            for (d = maxdepth; d >= 0; d--) {
                if (!(d in bucket)) continue
                n = split(substr(bucket[d], 2), items, SUBSEP)
                for (i = 1; i <= n; i++) {
                    p = items[i]
                    v = value[p]
                    c = covered[p] + 0
                    shown = (v >= min && c < v / 2)
                    if (shown) {
                        # Name the folder a person would recognise: climb out of
                        # chains such as .npm/_cacache/content-v2 while the
                        # parent holds hardly anything else (under 1% and 50 MB).
                        q = p
                        while (1) {
                            up = q
                            sub(/\/[^\/]*$/, "", up)
                            if (up == "") up = "/"
                            if (up == q || !(up in value)) break
                            extra = value[up] - value[q]
                            if (extra > 0.01 * value[up] || extra > 51200) break
                            q = up
                        }
                        if (!(q in printed)) printf "%.0f\t%s\n", value[q], q
                        printed[q] = 1
                    }
                    parent = p
                    sub(/\/[^\/]*$/, "", parent)
                    if (parent == "") parent = "/"
                    if (parent != p && (parent in value)) covered[parent] += shown ? v : c
                }
            }
        }' | sort -t "$(printf '\t')" -k1,1nr | awk -v n="$2" 'NR <= n'
}

scan_load() {
    local file="$1" key value line kb path change old min_kb snap safety
    SCAN_SKIPPED=0
    while IFS=$'\t' read -r _ key value; do
        case "$key" in
            status)     SCAN_STATUS="$value" ;;
            started)    SCAN_STARTED="$value" ;;
            finished)   SCAN_FINISHED="$value" ;;
            roots)      SCAN_ROOTS="$value" ;;
            unreadable) SCAN_UNREADABLE="$value" ;;
            skipped)    is_number "$value" && SCAN_SKIPPED=$((SCAN_SKIPPED + value)) ;;
        esac
    done < <(awk -F'\t' '$1 == "M"' "$file")

    # Growth against the comparison snapshot, when there is one.
    snap=""
    [ "$STATE_OK" -eq 1 ] && snap=$(growth_snapshot)
    if [ -n "$snap" ]; then
        GROWTH_SINCE=$(scan_meta "$snap" finished)
        mapfile -t GROW_ROWS < <(
            awk -F'\t' 'NR == FNR { if ($1 == "D") old[$4] = $2; next }
                        $1 == "D" { d = $2 - old[$4]; if (d > 0) print d "\t" $3 "\t" $4 }' \
                "$snap" "$file" | select_dirs "$TREND_MIN_GROWTH_KB" 5
        )
    fi

    min_kb=$(mb_to_kb "$DISK_TOP_MIN_MB")
    while IFS=$'\t' read -r kb path; do
        change="-"
        if [ -n "$snap" ]; then
            old=$(awk -F'\t' -v p="$path" '$1 == "D" && $4 == p {print $2; exit}' "$snap")
            change=$((kb - ${old:-0}))
        fi
        DIR_TOP_ROWS+=("$kb"$'\t'"$change"$'\t'"$path")
    done < <(awk -F'\t' '$1 == "D" {print $2 "\t" $3 "\t" $4}' "$file" \
                | select_dirs "$min_kb" "$DISK_TOP_COUNT")

    mapfile -t BIGFILE_ROWS < <(
        awk -F'\t' '$1 == "F" && $5 == "big" {print $2 "\t" $3 "\t" $6}' "$file" \
            | sort -t "$(printf '\t')" -k1,1nr | awk 'NR <= 5'
    )

    mapfile -t SAVING_ROWS < <(
        awk -F'\t' -v OFS='\t' '$1 == "S" {$1 = ""; sub(/^\t/, ""); print}' "$file" \
            | sort -t "$(printf '\t')" -k1,1nr
    )
    SAVINGS_SAFE_KB=0
    SAVINGS_REVIEW_KB=0
    for line in ${SAVING_ROWS[@]+"${SAVING_ROWS[@]}"}; do
        IFS=$'\t' read -r kb _ safety _ <<<"$line"
        is_number "$kb" || continue
        if [ "$safety" = "safe" ]; then
            SAVINGS_SAFE_KB=$((SAVINGS_SAFE_KB + kb))
        else
            SAVINGS_REVIEW_KB=$((SAVINGS_REVIEW_KB + kb))
        fi
    done

    # How much of each filesystem's used space the scanned roots account for.
    local root mount used scanned
    declare -A per_mount=()
    for root in $SCAN_ROOTS; do
        kb=$(awk -F'\t' -v p="$root" '$1 == "D" && $4 == p {print $2; exit}' "$file")
        is_number "${kb:-}" || continue
        mount=$(mount_of_path "$root")
        [ -n "$mount" ] || continue
        per_mount[$mount]=$(( ${per_mount[$mount]:-0} + kb ))
    done
    for mount in "${!per_mount[@]}"; do
        used=$(disk_row_field "$mount" 5) || continue
        scanned=${per_mount[$mount]}
        COVERAGE_ROWS+=("$mount|$scanned|$used")
    done
}

collect_disk_analysis() {
    RECLAIM_MIN_KB=$(mb_to_kb "$DISK_RECLAIM_MIN_MB")
    if [ "$DISK_SCAN" != "1" ]; then
        SCAN_STATUS="disabled"
        return 0
    fi

    local cache="" now finished age max_age need=0 rc tmp
    now=$(date +%s)
    if [ "$STATE_OK" -eq 1 ]; then cache="$STATE_DIR/scan.tsv"; fi

    if [ -n "$cache" ] && [ -s "$cache" ]; then
        finished=$(scan_meta "$cache" finished)
        is_number "$finished" || finished=0
        age=$((now - finished))
        max_age=$(awk -v h="$DISK_SCAN_MAX_AGE_HOURS" 'BEGIN {printf "%.0f", h * 3600 - 900}')
        # A manual run shows the cached scan with its age rather than starting a
        # long scan by surprise; cron (--notify) and --scan refresh it.
        if [ "$SCAN_MODE" = "force" ]; then
            need=1
        elif [ "$SCAN_MODE" = "auto" ] && [ "$NOTIFY_MODE" -eq 1 ] && [ "$age" -ge "$max_age" ]; then
            need=1
        fi
    elif [ "$SCAN_MODE" = "force" ]; then
        need=1
    elif [ "$SCAN_MODE" = "auto" ] && [ "$STATE_OK" -eq 1 ]; then
        need=1
    fi

    if [ "$need" -eq 1 ]; then
        if [ "$STATE_OK" -eq 1 ]; then
            with_lock scan.lock -n scan_refresh
            rc=$?
            if [ "$rc" -eq 75 ]; then
                SCAN_NOTE="Another folder scan is running; its result will show in the next report."
            fi
        else
            # No state directory: scan into a temporary file, use it once.
            tmp=$(mktemp "${TMPDIR:-/tmp}/vpsusagecheck-scan.XXXXXX") && {
                CLEANUP_PATHS+=("$tmp")
                scan_announce
                scan_run "$tmp"
                cache="$tmp"
            }
        fi
    fi

    if [ -n "$cache" ] && [ -s "$cache" ]; then
        scan_load "$cache"
    fi
    if [ "$STATE_OK" -eq 1 ] && [ -f "$STATE_DIR/scan.partial" ] && [ -z "$SCAN_NOTE" ]; then
        SCAN_NOTE="The last scan attempt ran out of time (DISK_SCAN_TIMEOUT=${DISK_SCAN_TIMEOUT} s); the figures may be incomplete."
    fi

    local notice_kb
    notice_kb=$(awk -v g="$DISK_RECLAIM_NOTICE_GB" 'BEGIN {printf "%.0f", g * 1048576}')
    if [ "$SAVINGS_SAFE_KB" -gt 0 ] && ! compare_gt "$notice_kb" "$SAVINGS_SAFE_KB"; then
        record_issue notice \
            "About $(kb_to_human "$SAVINGS_SAFE_KB") of disk space can be freed safely (see the savings list)" \
            disk-reclaimable
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Savings probes
# ---------------------------------------------------------------------------
# Each probe measures one kind of reclaimable space and prints S records (see
# the scan record format). Probes never delete anything; --clean re-runs them
# and acts through clean_action, never through the stored command text.

# emit_saving <kb> <category> <safe|review> <action> <path> <command> <note>
emit_saving() {
    local kb="$1" field line
    is_number "$kb" || return 0
    compare_gt "$RECLAIM_MIN_KB" "$kb" && return 0
    [ "$kb" = "0" ] && return 0
    line="S"$'\t'"$kb"
    shift
    for field in "$@"; do
        field=${field//[[:cntrl:]]/ }
        line+=$'\t'"${field:--}"
    done
    printf '%s\n' "$line"
}

# saving_id <action> <path>: the short, stable name of a safe item, used by
# `--free` and in alerts ("pnpm-store", "cache:pip", "next-cache:mysite").
# Items in another user's home carry "@owner". Review items have no name.
saving_id() {
    local action="$1" path="$2" id owner site
    case "$action" in
        journal-vacuum) id="journal" ;;
        apt-clean)      id="apt" ;;
        snap-remove)    id="snaps" ;;
        npm-cache)      id="npm-cache" ;;
        pnpm-prune)     id="pnpm-store" ;;
        conda-clean)    id="conda-pkgs" ;;
        docker-builder) id="docker-build" ;;
        rm-dir)
            case "$path" in
                */.next/cache)
                    site=${path%/.next/cache}
                    id="next-cache:${site##*/}"
                    ;;
                */.cache/*) id="cache:${path##*/}" ;;
                *)          id="dir:${path##*/}" ;;
            esac
            ;;
        prune-versions:*)
            case "$path" in
                */.warp/*)             id="old-versions:warp" ;;
                */.vscode-server/bin)  id="old-versions:vscode" ;;
                */.vscode-server/*)    id="old-versions:vscode-cli" ;;
                */.cursor-server/bin)  id="old-versions:cursor" ;;
                */.cursor-server/*)    id="old-versions:cursor-cli" ;;
                *)                     id="old-versions:${path##*/}" ;;
            esac
            ;;
        *)
            printf -- '-'
            return
            ;;
    esac
    case "$action" in
        journal-vacuum|apt-clean|snap-remove|docker-builder) ;;
        *)
            owner=$(stat -c %U -- "$path" 2>/dev/null)
            if [ -n "$owner" ] && [ "$owner" != "$ME" ]; then id+="@$owner"; fi
            ;;
    esac
    printf '%s' "$id"
}

# Actions that need root (through sudo) when we are not root.
action_needs_root() {
    [ "$EUID" -ne 0 ] || return 1
    case "$1" in journal-vacuum|apt-clean|snap-remove) return 0 ;; esac
    return 1
}

# Size of a directory tree in KB (0 when it cannot be read).
dir_kb() {
    du -sxk -- "$1" 2>/dev/null | awk 'END {printf "%.0f", $1 + 0}'
}

# Total size of the files under a directory that have a single link, i.e. are
# not hard-linked into any project. That is what `pnpm store prune` deletes,
# and for conda what no environment uses.
linkcount1_kb() {
    local root="$1" filter="${2:-*}"
    find "$root" -xdev -type f -links 1 -path "$filter" -printf '%k\n' 2>/dev/null \
        | awk '{s += $1} END {printf "%.0f", s}'
}

root_prefix() { [ "$EUID" -eq 0 ] || printf 'sudo '; }

# Prefix for a command that must run as the owner of the files: nothing when
# that is us, sudo -u when we are root, plain sudo otherwise.
owner_prefix() {
    if [ "$1" = "$ME" ]; then return 0; fi
    if [ "$EUID" -eq 0 ]; then printf 'sudo -u %q -H ' "$1"; else printf 'sudo '; fi
}

probe_journal() {
    command_exists journalctl || return 0
    local out kb keep reclaim
    out=$(journalctl --disk-usage 2>/dev/null) || return 0
    # "Archived and active journals take up 996.0M in the file system."
    kb=$(printf '%s\n' "$out" | awk '{
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+[BKMGT]$/) {
            u = substr($i, length($i)); v = substr($i, 1, length($i) - 1)
            f = (u == "B") ? 1 / 1024 : (u == "K") ? 1 : (u == "M") ? 1024 : (u == "G") ? 1048576 : 1073741824
            printf "%.0f", v * f
            exit
        }}')
    is_number "$kb" || return 0
    keep=$(mb_to_kb "$DISK_JOURNAL_KEEP_MB")
    reclaim=$((kb - keep))
    [ "$reclaim" -gt 0 ] || return 0
    emit_saving "$reclaim" "System journal" safe journal-vacuum /var/log/journal \
        "$(root_prefix)journalctl --vacuum-size=${DISK_JOURNAL_KEEP_MB}M" \
        "The system logs take $(kb_to_human "$kb"); this keeps the newest ${DISK_JOURNAL_KEEP_MB} MB and deletes older entries."
}

probe_apt() {
    [ -d /var/cache/apt/archives ] || return 0
    local kb
    kb=$(find /var/cache/apt/archives -maxdepth 1 -type f -name '*.deb' -printf '%k\n' 2>/dev/null \
        | awk '{s += $1} END {printf "%.0f", s}')
    emit_saving "$kb" "Downloaded package files (APT)" safe apt-clean /var/cache/apt/archives \
        "$(root_prefix)apt-get clean" \
        "Installers APT keeps after installing packages; they are downloaded again if ever needed."
}

# "name revision" of every disabled snap revision.
disabled_snaps() {
    snap list --all 2>/dev/null | awk 'NR > 1 && $NF ~ /disabled/ {print $1, $3}'
}

probe_snaps() {
    command_exists snap || return 0
    local name rev size kb=0 count=0
    while read -r name rev; do
        size=$(stat -c '%b %B' -- "/var/lib/snapd/snaps/${name}_${rev}.snap" 2>/dev/null \
            | awk '{printf "%.0f", $1 * $2 / 1024}')
        is_number "$size" || continue
        kb=$((kb + size))
        count=$((count + 1))
    done < <(disabled_snaps)
    [ "$count" -gt 0 ] || return 0
    emit_saving "$kb" "Old snap revisions ($count)" safe snap-remove /var/lib/snapd/snaps \
        "snap list --all | awk '/disabled/ {print \$1, \$3}' | while read -r n r; do $(root_prefix)snap remove \"\$n\" --revision=\"\$r\"; done" \
        "Previous versions snapd keeps after each update; '$(root_prefix)snap set system refresh.retain=2' keeps fewer from now on."
}

probe_rotated_logs() {
    [ -d /var/log ] || return 0
    local kb
    kb=$(find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].log' -o -name '*.old' \) \
        -printf '%k\n' 2>/dev/null | awk '{s += $1} END {printf "%.0f", s}')
    emit_saving "$kb" "Rotated system logs" review none /var/log \
        "$(root_prefix)find /var/log -type f \\( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].log' -o -name '*.old' \\) -delete" \
        "Older log files kept by logrotate; delete them only if their history is not needed."
}

probe_autoremove() {
    command_exists apt-get && command_exists dpkg-query || return 0
    local -a pkgs=()
    local kb
    mapfile -t pkgs < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}')
    [ ${#pkgs[@]} -gt 0 ] || return 0
    kb=$(dpkg-query -W -f='${Installed-Size}\n' "${pkgs[@]}" 2>/dev/null \
        | awk '{s += $1} END {printf "%.0f", s}')
    emit_saving "$kb" "Packages no longer needed (${#pkgs[@]})" review none - \
        "$(root_prefix)apt-get autoremove --purge" \
        "Dependencies left behind by removed software; read the list apt shows before confirming."
}

# Docker prints decimal units ("1.234GB", "0B").
docker_size_kb() {
    awk -v s="$1" 'BEGIN {
        if (match(s, /^[0-9.]+/) == 0) { print 0; exit }
        v = substr(s, 1, RLENGTH); u = substr(s, RLENGTH + 1)
        f = (u == "kB") ? 1000 : (u == "MB") ? 1e6 : (u == "GB") ? 1e9 : (u == "TB") ? 1e12 : 1
        printf "%.0f", v * f / 1024
    }'
}

probe_docker() {
    command_exists docker || return 0
    run_limited 20 docker info >/dev/null 2>&1 || return 0
    local type reclaim kb
    while IFS=$'\t' read -r type reclaim; do
        kb=$(docker_size_kb "${reclaim%% *}")
        case "$type" in
            "Build Cache")
                emit_saving "$kb" "Docker build cache" safe docker-builder - \
                    "docker builder prune -f" \
                    "Intermediate layers from image builds; rebuilt when an image is built again." ;;
            Images)
                emit_saving "$kb" "Unused Docker images" review none - \
                    "docker image prune -a" \
                    "Images that no container uses; they must be pulled again before use." ;;
        esac
    done < <(run_limited 20 docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)
}

# old_versions <parent> <glob>: the matching versions except the two most
# recently modified, one per line. A version is a directory (VS Code, Cursor)
# or a single binary (Warp).
old_versions() {
    find "$1" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -name "$2" \
        -printf '%T@\t%p\n' 2>/dev/null \
        | sort -t "$(printf '\t')" -k1,1nr | awk -F'\t' 'NR > 2 {print $2}'
}

# probe_home <home> <owner>: caches of package managers and tools in one home.
probe_home() {
    local home="$1" owner="$2" as d store total unref base kb sub name others spec
    local parent glob label cmd safe_sum cache_total
    local -a old=()
    as=$(owner_prefix "$owner")

    d="$home/.npm/_cacache"
    if [ -d "$d" ]; then
        emit_saving "$(dir_kb "$d")" "npm download cache" safe npm-cache "$d" \
            "${as}npm cache clean --force" \
            "Packages npm keeps after downloading them; fetched again when needed."
    fi

    # A pnpm store keeps one layout per major version (store/v10, store/v11).
    # `pnpm store prune` cleans only the layout of the pnpm that runs it, so an
    # older layout is a separate item, to be pruned with that older pnpm.
    local pnpm_bin pnpm_major="" layout version prune_with
    if pnpm_bin=$(find_pnpm); then
        pnpm_major=$(run_limited 20 "$pnpm_bin" --version 2>/dev/null | head -n 1 | cut -d. -f1)
    fi
    for store in "$home/.local/share/pnpm/store" "$home/.pnpm-store"; do
        [ -d "$store" ] || continue
        for layout in "$store"/v*; do
            [ -d "$layout/files" ] || continue
            version=${layout##*/v}
            total=$(dir_kb "$layout")
            unref=$(linkcount1_kb "$layout" '*/files/*')
            if [ -n "$pnpm_major" ] && [ "$version" = "$pnpm_major" ]; then
                emit_saving "$unref" "pnpm store: packages no project uses" safe pnpm-prune "$store" \
                    "${as}pnpm store prune" \
                    "This store layout (v$version) holds $(kb_to_human "$total"); this part is not linked into any installed project."
            else
                # pnpm 7 to 9 used the layout v3.
                prune_with=$version
                [ "$version" = "3" ] && prune_with=9
                emit_saving "$unref" "Old pnpm store layout v$version: packages no project uses" review none "$layout" \
                    "${as}pnpm dlx pnpm@$prune_with store prune --store-dir $(printf '%q' "$store")" \
                    "Left by pnpm $prune_with ($(kb_to_human "$total") in all). Projects still installed with that pnpm use the rest; once they are reinstalled with the current pnpm, the whole folder can go."
            fi
        done
    done

    for base in "$home/miniconda3" "$home/anaconda3" "$home/miniforge3" "$home/mambaforge"; do
        [ -d "$base/pkgs" ] || continue
        emit_saving "$(linkcount1_kb "$base/pkgs")" "Conda package cache" safe conda-clean "$base/pkgs" \
            "${as}$(printf '%q' "$base/bin/conda") clean --all --yes" \
            "Downloaded archives and unpacked packages that no environment uses."
    done

    if [ -d "$home/.cache" ]; then
        safe_sum=0
        cache_total=0
        others=""
        while IFS=$'\t' read -r kb sub; do
            is_number "$kb" || continue
            if [ "$sub" = "$home/.cache" ]; then cache_total=$kb; continue; fi
            name=${sub##*/}
            case " $SAFE_CACHE_DIRS " in
                *" $name "*)
                    if ! compare_gt "$RECLAIM_MIN_KB" "$kb"; then safe_sum=$((safe_sum + kb)); fi
                    emit_saving "$kb" "Cache of $name" safe rm-dir "$sub" \
                        "$(owner_prefix "$owner")rm -rf -- $(printf '%q' "$sub")" \
                        "Downloaded files kept by $name; fetched again when needed."
                    ;;
                *)
                    others+="$kb"$'\t'"$name"$'\n'
                    ;;
            esac
        done < <(du -xk -d1 -- "$home/.cache" 2>/dev/null)
        kb=$((cache_total - safe_sum))
        others=$(printf '%s' "$others" | sort -t "$(printf '\t')" -k1,1nr | awk -F'\t' 'NR <= 3' \
            | while IFS=$'\t' read -r kb2 name; do printf '%s %s, ' "$name" "$(kb_to_human "$kb2")"; done)
        emit_saving "$kb" "Other caches in $home/.cache" review none "$home/.cache" \
            "du -sh $(printf '%q' "$home/.cache")/* | sort -h" \
            "Largest: ${others%, }. Most rebuild themselves, but some (browser binaries, models) must be downloaded again by the program that uses them."
    fi

    # The remote servers of Warp, VS Code and Cursor leave one copy per release
    # behind.
    for spec in ".warp/remote-server|oz-v*|Warp" \
                ".vscode-server/bin|*|VS Code" ".vscode-server/cli/servers|Stable-*|VS Code" \
                ".cursor-server/bin|*|Cursor" ".cursor-server/cli/servers|Stable-*|Cursor"; do
        IFS='|' read -r parent glob label <<<"$spec"
        parent="$home/$parent"
        [ -d "$parent" ] || continue
        mapfile -t old < <(old_versions "$parent" "$glob")
        [ ${#old[@]} -gt 0 ] || continue
        kb=0
        cmd="$(owner_prefix "$owner")rm -rf --"
        for d in "${old[@]}"; do
            kb=$((kb + $(dir_kb "$d")))
            cmd+=" $(printf '%q' "$d")"
        done
        emit_saving "$kb" "Old $label remote-server versions (${#old[@]})" safe "prune-versions:$glob" "$parent" \
            "$cmd" \
            "Earlier releases left behind by automatic updates; the two newest are kept."
    done
}

probe_homes() {
    local home owner
    if [ "$EUID" -eq 0 ]; then
        for home in /root /home/*; do
            [ -d "$home" ] && [ ! -L "$home" ] || continue
            owner=$(stat -c %U -- "$home" 2>/dev/null) || continue
            probe_home "$home" "$owner"
        done
    elif [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
        probe_home "$HOME" "$ME"
    fi
}

# probe_next_caches: reads .next/cache paths on stdin.
probe_next_caches() {
    local path site owner
    while IFS= read -r path; do
        [ -d "$path" ] && [ ! -L "$path" ] || continue
        site=${path%/.next/cache}
        site=${site##*/}
        owner=$(stat -c %U -- "$path" 2>/dev/null)
        emit_saving "$(dir_kb "$path")" "Next.js build cache of $site" safe rm-dir "$path" \
            "$(owner_prefix "$owner")rm -rf -- $(printf '%q' "$path")" \
            "Rebuilt by the next build; optimised images are regenerated on first request."
    done
}

# probe_files: reads "kb mtime nlink kind path" for the large files and logs.
probe_files() {
    local kb mtime nlink kind path now owner
    now=$(date +%s)
    while IFS=$'\t' read -r kb mtime nlink kind path; do
        is_number "$mtime" || continue
        owner=$(stat -c %U -- "$path" 2>/dev/null)
        case "$kind" in
            log)
                emit_saving "$kb" "Large log file" review none "$path" \
                    "$(owner_prefix "$owner")truncate -s 0 -- $(printf '%q' "$path")" \
                    "Last written $(date -d "@$mtime" +%F 2>/dev/null); check that it is rotated. Truncating keeps the file the program writes to."
                ;;
            big)
                # Git packs are the repository itself, and a file with several
                # links frees nothing when one of them is removed.
                case "$path" in */.git/*) continue ;; esac
                [ "$nlink" = "1" ] || continue
                [ $((now - mtime)) -gt $((STALE_FILE_DAYS * 86400)) ] || continue
                emit_saving "$kb" "Large file untouched since $(date -d "@$mtime" +%F 2>/dev/null)" review none "$path" \
                    "ls -l -- $(printf '%q' "$path")" \
                    "Not modified for over $STALE_FILE_DAYS days; check whether it is still needed."
                ;;
        esac
    done
}

# scan_savings <records file>: every probe; .next/cache paths and large files
# come from the N and F records of the scan.
scan_savings() {
    local records="$1"
    probe_journal
    probe_apt
    probe_snaps
    probe_rotated_logs
    probe_autoremove
    probe_docker
    probe_homes
    awk -F'\t' '$1 == "N" {print $2}' "$records" | probe_next_caches
    awk -F'\t' -v OFS='\t' '$1 == "F" {print $2, $3, $4, $5, $6}' "$records" | probe_files
}

# ---------------------------------------------------------------------------
# Deleted files still held open
# ---------------------------------------------------------------------------
# A log deleted while a daemon still writes to it keeps its space until the
# daemon closes it: df counts it, du cannot see it. Only our own processes are
# visible unless running as root.
DELETED_ROWS=()       # kb <TAB> pid <TAB> process <TAB> path
DELETED_KB=0

collect_deleted_open() {
    [ -d /proc/self/fd ] || return 0
    local link target pid size key comm dir type
    declare -A seen=() dir_type=()
    local -a rows=()
    while IFS=$'\t' read -r link target; do
        target=${target% (deleted)}
        case "$target" in
            /memfd:*|/dev/*|/SYSV*|/proc/*) continue ;;
            /*) ;;
            *) continue ;;
        esac
        # A deleted file on tmpfs occupies memory, not disk.
        dir=$(dirname -- "$target")
        if [ -z "${dir_type[$dir]+set}" ]; then
            dir_type[$dir]=$(df -PT -- "$dir" 2>/dev/null | awk 'NR == 2 {print $2}')
        fi
        type=${dir_type[$dir]}
        if [ -z "$type" ] || is_ignored_fs_type "$type"; then continue; fi
        read -r size key < <(stat -L -c '%b %B %d:%i' -- "$link" 2>/dev/null \
            | awk '{printf "%.0f %s\n", $1 * $2 / 1024, $3}')
        is_number "${size:-}" || continue
        [ -n "${seen[$key]:-}" ] && continue
        seen[$key]=1
        pid=${link#/proc/}
        pid=${pid%%/*}
        comm=$(cat "/proc/$pid/comm" 2>/dev/null)
        DELETED_KB=$((DELETED_KB + size))
        rows+=("$size"$'\t'"$pid"$'\t'"${comm:-?}"$'\t'"$target")
    done < <(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname '*(deleted)' \
                -printf '%p\t%l\n' 2>/dev/null)

    compare_gt "$RECLAIM_MIN_KB" "$DELETED_KB" && return 0
    [ "$DELETED_KB" -gt 0 ] || return 0
    mapfile -t DELETED_ROWS < <(printf '%s\n' "${rows[@]}" \
        | sort -t "$(printf '\t')" -k1,1nr | awk 'NR <= 5')
    if [ "$DELETED_KB" -ge "$DELETED_OPEN_NOTICE_KB" ]; then
        local top_comm top_pid
        IFS=$'\t' read -r _ top_pid top_comm _ <<<"${DELETED_ROWS[0]}"
        record_issue notice \
            "Deleted files still held open use $(kb_to_human "$DELETED_KB"); restarting $top_comm (pid $top_pid) releases the largest" \
            deleted-open
    fi
}

# ---------------------------------------------------------------------------
# Interactive clean-up (--clean)
# ---------------------------------------------------------------------------
# Offers only the "safe" savings, one at a time, and acts through a fixed table
# of actions with argument arrays. Paths come from a fresh probe run and are
# checked again just before removal; no stored command text is ever executed.

# Paths --clean may remove, by shape.
clean_path_allowed() {
    case "$1" in
        */.next/cache) return 0 ;;
        */.npm/_cacache) return 0 ;;
        */.cache/pip|*/.cache/uv|*/.cache/pnpm|*/.cache/yarn|*/.cache/node-gyp|*/.cache/go-build) return 0 ;;
        */.warp/remote-server/*|*/.vscode-server/bin/*|*/.vscode-server/cli/servers/*) return 0 ;;
        */.cursor-server/bin/*|*/.cursor-server/cli/servers/*) return 0 ;;
    esac
    return 1
}

safe_remove() {
    local path="$1"
    if [ -L "$path" ] || { [ ! -d "$path" ] && [ ! -f "$path" ]; }; then
        warn "not a file or directory, left alone: $path"
        return 1
    fi
    if ! clean_path_allowed "$path"; then
        warn "refusing to remove $path"
        return 1
    fi
    rm -rf -- "$path"
}

# Tools that clean a user's own cache must run as that user.
clean_owned_by_me() {
    local owner
    owner=$(stat -c %U -- "$1" 2>/dev/null)
    if [ "$owner" = "$ME" ]; then return 0; fi
    printf '      This belongs to %s; run the command above as that user.\n' "${owner:-another user}"
    return 1
}

find_pnpm() {
    local candidate
    for candidate in "$(command -v pnpm 2>/dev/null)" "$HOME/.local/share/pnpm/pnpm" \
                     "$HOME/.npm-global/bin/pnpm"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

clean_action() {
    local action="$1" path="$2" name rev dir pnpm rc=0
    local -a sudo_cmd=()
    if [ "$EUID" -ne 0 ]; then
        # Without a terminal nobody can type a password: sudo -n fails at once
        # instead of waiting, unless sudo is passwordless for the command.
        if [ "$CLEAN_NONINTERACTIVE" -eq 1 ]; then sudo_cmd=(sudo -n); else sudo_cmd=(sudo); fi
    fi
    case "$action" in
        journal-vacuum)
            ${sudo_cmd[@]+"${sudo_cmd[@]}"} journalctl --vacuum-size="${DISK_JOURNAL_KEEP_MB}M"
            ;;
        apt-clean)
            ${sudo_cmd[@]+"${sudo_cmd[@]}"} apt-get clean
            ;;
        snap-remove)
            while read -r name rev; do
                ${sudo_cmd[@]+"${sudo_cmd[@]}"} snap remove "$name" --revision="$rev" || rc=1
            done < <(disabled_snaps)
            return "$rc"
            ;;
        npm-cache)
            clean_owned_by_me "$path" || return 1
            if command_exists npm; then
                npm cache clean --force
            else
                safe_remove "$path"
            fi
            ;;
        pnpm-prune)
            clean_owned_by_me "$path" || return 1
            pnpm=$(find_pnpm) || { warn "pnpm is not on the PATH"; return 1; }
            "$pnpm" store prune --store-dir "$path"
            ;;
        conda-clean)
            clean_owned_by_me "$path" || return 1
            [ -x "${path%/pkgs}/bin/conda" ] || { warn "no conda next to $path"; return 1; }
            "${path%/pkgs}/bin/conda" clean --all --yes
            ;;
        rm-dir)
            if [ "$EUID" -ne 0 ]; then clean_owned_by_me "$path" || return 1; fi
            safe_remove "$path"
            ;;
        prune-versions:*)
            if [ "$EUID" -ne 0 ]; then clean_owned_by_me "$path" || return 1; fi
            while IFS= read -r dir; do
                safe_remove "$dir" || rc=1
            done < <(old_versions "$path" "${action#prune-versions:}")
            return "$rc"
            ;;
        docker-builder)
            docker builder prune -f
            ;;
        *)
            return 1
            ;;
    esac
}

# Free space, in KB, on the filesystem holding a path (or its nearest
# existing ancestor, since the path itself may be gone afterwards).
avail_kb_for() {
    local path="$1"
    while [ ! -e "$path" ] && [ "$path" != "/" ] && [ -n "$path" ]; do
        path=$(dirname -- "$path")
    done
    df -Pk -- "${path:-/}" 2>/dev/null | awk 'NR == 2 {print $4}'
}

# The same probes as a scan, without the expensive folder traversal: the
# .next/cache locations come from the cached scan when there is one.
clean_candidates() {
    local cache="$STATE_DIR/scan.tsv" root
    probe_journal
    probe_apt
    probe_snaps
    probe_docker
    probe_homes
    if [ "$STATE_OK" -eq 1 ] && [ -s "$cache" ]; then
        awk -F'\t' '$1 == "N" {print $2}' "$cache" | probe_next_caches
    else
        while IFS= read -r root; do
            find "$root" -xdev -type d -path '*/.next/cache' -print -prune 2>/dev/null
        done < <(scan_roots) | probe_next_caches
    fi
}

run_clean() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '%s: --clean asks before each step, so it must run in a terminal;\n' "$PROGNAME" >&2
        printf 'to free the safe items without questions use --clean --yes, or --free NAME,NAME\n' >&2
        exit "$EXIT_USAGE"
    fi
    RECLAIM_MIN_KB=$(mb_to_kb "$DISK_RECLAIM_MIN_MB")
    collect_disk

    printf '%sLooking for space that can be freed safely...%s\n' "$CYAN" "$NC"
    local -a items=()
    mapfile -t items < <(clean_candidates | awk -F'\t' '$4 == "safe"' \
        | sort -t "$(printf '\t')" -k2,2nr)
    if [ ${#items[@]} -eq 0 ]; then
        printf 'Nothing to free: no safe item is larger than %s MB.\n' "$DISK_RECLAIM_MIN_MB"
        return 0
    fi

    local item kb category action path command note answer before after freed
    local total=0 i=0
    for item in "${items[@]}"; do
        i=$((i + 1))
        IFS=$'\t' read -r _ kb category _ action path command note <<<"$item"
        printf '\n%s[%d/%d] %s, about %s%s\n' "$BOLD" "$i" "${#items[@]}" \
            "$category" "$(kb_to_human "$kb")" "$NC"
        printf '      %s\n' "$note"
        printf '      %s%s%s\n' "$YELLOW" "$command" "$NC"
        answer=""
        read -r -p "      Free it? [y/N] " answer || answer=""
        case "$answer" in
            y|Y|yes|Yes|YES) ;;
            *) printf '      Skipped.\n'; continue ;;
        esac
        before=$(avail_kb_for "$path")
        if clean_action "$action" "$path"; then
            after=$(avail_kb_for "$path")
            freed=0
            if is_number "$before" && is_number "$after" && [ "$after" -gt "$before" ]; then
                freed=$((after - before))
            fi
            total=$((total + freed))
            printf '      %sDone: %s freed.%s\n' "$GREEN" "$(kb_to_human "$freed")" "$NC"
        else
            printf '      %sThis step did not complete.%s\n' "$RED" "$NC"
        fi
    done
    printf '\n%sFreed about %s in total.%s\n' "$BOLD" "$(kb_to_human "$total")" "$NC"

    # Keep the cached savings list truthful for the next report.
    if [ "$STATE_OK" -eq 1 ] && [ -s "$STATE_DIR/scan.tsv" ]; then
        with_lock scan.lock 30 refresh_cached_savings
    fi
    return 0
}

refresh_cached_savings() {
    local cache="$STATE_DIR/scan.tsv" fresh
    fresh=$(mktemp "${TMPDIR:-/tmp}/vpsusagecheck-savings.XXXXXX") || return 1
    CLEANUP_PATHS+=("$fresh")
    scan_savings "$cache" > "$fresh"
    { awk -F'\t' '$1 != "S"' "$cache"; cat "$fresh"; } | atomic_replace "$cache"
}

# ---------------------------------------------------------------------------
# Non-interactive clean-up (--free), for an agent acting on a reply
# ---------------------------------------------------------------------------
# `--free list` shows the safe items with their names; `--free all` or
# `--free pnpm-store,npm-cache` frees them without asking. Only the safe items
# exist here, and every one goes through clean_action, so whoever calls this
# (the Hermes agent answering a reply to an alert) can free space but cannot
# delete anything else. The output is short plain text, meant to be relayed.

free_list() {
    local item kb category action path id mark
    if [ $# -eq 0 ]; then
        printf 'Nothing can be freed safely right now (no item above %s MB).\n' "$DISK_RECLAIM_MIN_MB"
        return
    fi
    printf 'Space that can be freed safely on %s:\n' "$(hostname)"
    for item in "$@"; do
        IFS=$'\t' read -r _ kb category _ action path _ _ <<<"$item"
        id=$(saving_id "$action" "$path")
        mark=""
        action_needs_root "$action" && mark="  (needs the administrator's password)"
        printf '  %-32s %10s  %s%s\n' "$id" "$(kb_to_human "$kb")" "$category" "$mark"
    done
    printf 'Free them with: %s --free all   or, for some: %s --free NAME,NAME\n' "$PROGNAME" "$PROGNAME"
}

run_free() {
    RECLAIM_MIN_KB=$(mb_to_kb "$DISK_RECLAIM_MIN_MB")
    CLEAN_NONINTERACTIVE=1
    collect_disk

    local -a items=() selected=() unknown=() wanted=()
    local item want id found kb category action path command log before after freed
    local total=0 failed=0 root_free
    mapfile -t items < <(clean_candidates | awk -F'\t' '$4 == "safe"' \
        | sort -t "$(printf '\t')" -k2,2nr)

    case "$FREE_REQUEST" in
        ""|list)
            free_list ${items[@]+"${items[@]}"}
            return 0
            ;;
        all)
            selected=(${items[@]+"${items[@]}"})
            ;;
        *)
            IFS=', ' read -r -a wanted <<<"$FREE_REQUEST"
            for want in ${wanted[@]+"${wanted[@]}"}; do
                found=0
                for item in ${items[@]+"${items[@]}"}; do
                    IFS=$'\t' read -r _ _ _ _ action path _ _ <<<"$item"
                    if [ "$(saving_id "$action" "$path")" = "$want" ]; then
                        selected+=("$item")
                        found=1
                        break
                    fi
                done
                [ "$found" -eq 1 ] || unknown+=("$want")
            done
            ;;
    esac

    if [ ${#unknown[@]} -gt 0 ]; then
        printf 'Not a safe item that can be freed now: %s\n' "${unknown[*]}"
        free_list ${items[@]+"${items[@]}"}
        [ ${#selected[@]} -gt 0 ] || return "$EXIT_USAGE"
        printf '\n'
    fi
    if [ ${#selected[@]} -eq 0 ]; then
        printf 'Nothing can be freed safely right now.\n'
        return 0
    fi

    log=$(mktemp "${TMPDIR:-/tmp}/vpsusagecheck-free.XXXXXX") || return 1
    CLEANUP_PATHS+=("$log")
    for item in "${selected[@]}"; do
        IFS=$'\t' read -r _ kb category _ action path command _ <<<"$item"
        id=$(saving_id "$action" "$path")
        before=$(avail_kb_for "$path")
        if clean_action "$action" "$path" > "$log" 2>&1 < /dev/null; then
            after=$(avail_kb_for "$path")
            freed=0
            if is_number "$before" && is_number "$after" && [ "$after" -gt "$before" ]; then
                freed=$((after - before))
            fi
            total=$((total + freed))
            printf 'Freed %s: %s (%s).\n' "$(kb_to_human "$freed")" "$category" "$id"
        else
            failed=$((failed + 1))
            if action_needs_root "$action"; then
                printf 'Not freed: %s (%s) needs the administrator'"'"'s password. Run on the server: %s\n' \
                    "$category" "$id" "$command"
            else
                printf 'Not freed: %s (%s). The clean-up said: %s\n' "$category" "$id" \
                    "$(tail -n 3 "$log" | tr '\n' ' ' | cut -c1-300)"
            fi
        fi
    done
    root_free=$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')
    printf 'In total about %s freed; / now has %s free.\n' "$(kb_to_human "$total")" \
        "$(kb_to_human "$root_free")"

    if [ "$STATE_OK" -eq 1 ] && [ -s "$STATE_DIR/scan.tsv" ]; then
        with_lock scan.lock 30 refresh_cached_savings
    fi
    [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Notification
# ---------------------------------------------------------------------------
# With --notify, a short plain-text digest goes out when an issue at or above
# NOTIFY_MIN_LEVEL appears or gets worse, again every NOTIFY_REPEAT_HOURS while
# it lasts, and once more when everything is back to normal. notify.state
# remembers the last message: its epoch on the first line, then the
# "level:key" pairs it covered.
readonly NOTIFY_MAX_CHARS=3500

notify_configured() { [ -n "$NOTIFY_HERMES_TO" ] || [ -n "$NOTIFY_COMMAND" ]; }

# cron's PATH does not include ~/.local/bin, where Hermes installs itself.
find_hermes() {
    if [ -n "$HERMES_BIN" ]; then printf '%s' "$HERMES_BIN"; return 0; fi
    if command_exists hermes; then command -v hermes; return 0; fi
    if [ -x "$HOME/.local/bin/hermes" ]; then printf '%s' "$HOME/.local/bin/hermes"; return 0; fi
    return 1
}

# Sorted "level:key" lines for the issues at or above NOTIFY_MIN_LEVEL.
current_alert_keys() {
    local i level min
    min=$(level_rank "$NOTIFY_MIN_LEVEL")
    for i in ${ISSUES[@]+"${!ISSUES[@]}"}; do
        level="${ISSUES[$i]%%|*}"
        [ "$(level_rank "$level")" -ge "$min" ] || continue
        printf '%s:%s\n' "$level" "${ISSUE_KEYS[$i]}"
    done | sort -u
}

status_label() {
    case "$OVERALL_STATUS" in
        "$EXIT_CRITICAL") printf 'CRITICAL' ;;
        "$EXIT_WARNING")  printf 'WARNING' ;;
        *)                printf 'OK' ;;
    esac
}

# notify_subject <kind> <new keys>
notify_subject() {
    local kind="$1" newkeys="$2" host i level best="" best_rank=0 rank pair
    host=$(hostname)
    case "$kind" in
        recovery) printf 'VPS %s: all clear' "$host"; return ;;
        test)     printf 'VPS %s: test message' "$host"; return ;;
    esac
    # Headline: the most severe new issue (an alert) or open issue (a reminder).
    for i in ${ISSUES[@]+"${!ISSUES[@]}"}; do
        level="${ISSUES[$i]%%|*}"
        pair="$level:${ISSUE_KEYS[$i]}"
        if [ "$kind" = "alert" ] && ! grep -qxF -- "$pair" <<<"$newkeys"; then
            continue
        fi
        rank=$(level_rank "$level")
        if [ "$rank" -gt "$best_rank" ]; then
            best_rank=$rank
            best="${ISSUES[$i]#*|}"
        fi
    done
    if [ "$kind" = "reminder" ]; then
        printf 'VPS %s: still %s, %s' "$host" "$(status_label)" "$best"
    else
        printf 'VPS %s: %s, %s' "$host" "$(status_label)" "$best"
    fi
}

# notify_digest <kind> <new keys>: the message body, plain text.
notify_digest() {
    local kind="$1" newkeys="$2" host row mount state slope days pct size used
    local i level message mark count=0 line kb category safety action path
    host=$(hostname)
    case "$kind" in
        recovery)
            printf 'All clear on %s: the problems reported earlier are gone.\n' "$host"
            return
            ;;
        test)
            printf 'This is a test message from vpsusagecheck on %s. Real alerts look like the text below.\n\n' "$host"
            ;;
        reminder)
            printf 'These problems on %s are still open.\n\n' "$host"
            ;;
    esac

    for row in ${TREND_ROWS[@]+"${TREND_ROWS[@]}"}; do
        IFS='|' read -r mount state slope _ days _ _ _ <<<"$row"
        [ "$state" = "growing" ] || continue
        compare_gt "$days" 365 && continue
        pct=$(disk_row_field "$mount" 7)
        size=$(disk_row_field "$mount" 4)
        used=$(disk_row_field "$mount" 5)
        printf 'The disk %s is %s%% full (%s of %s) and grows by about %s a day; at this pace it will be full in %s, around %s.\n\n' \
            "$mount" "${pct:-?}" "$(kb_to_human "$used")" "$(kb_to_human "$size")" \
            "$(kb_to_human "$slope")" "$(days_phrase "$days")" \
            "$(date -d "@$(awk -v d="$days" -v n="$(date +%s)" 'BEGIN {printf "%.0f", n + d * 86400}')" '+%-d %b' 2>/dev/null)"
    done

    if [ ${#ISSUES[@]} -gt 0 ]; then
        printf 'What needs attention:\n'
        for i in "${!ISSUES[@]}"; do
            level="${ISSUES[$i]%%|*}"
            message="${ISSUES[$i]#*|}"
            mark=""
            if [ "$kind" = "alert" ] && grep -qxF -- "$level:${ISSUE_KEYS[$i]}" <<<"$newkeys"; then
                mark=" (new)"
            fi
            printf -- '- [%s] %s%s\n' "$level" "$message" "$mark"
        done
        printf '\n'
    else
        printf 'Nothing needs attention right now.\n\n'
    fi

    if [ "$SAVINGS_SAFE_KB" -gt 0 ]; then
        printf 'Space that can be freed safely, about %s:\n' "$(kb_to_human "$SAVINGS_SAFE_KB")"
        for line in ${SAVING_ROWS[@]+"${SAVING_ROWS[@]}"}; do
            IFS=$'\t' read -r kb category safety action path _ _ <<<"$line"
            [ "$safety" = "safe" ] || continue
            count=$((count + 1))
            [ "$count" -le 6 ] || break
            mark=""
            action_needs_root "$action" && mark=", needs your password"
            printf -- '- %s, %s (%s%s)\n' "$(kb_to_human "$kb")" "$category" \
                "$(saving_id "$action" "$path")" "$mark"
        done
        if [ -n "$NOTIFY_HERMES_TO" ]; then
            printf '\nTo free them, reply to this message, for example "free everything safe" or "free pnpm-store and npm-cache"; Hermes then runs %s --free for you.\n' "$PROGNAME"
        else
            printf '\nTo free them: %s --free all, or %s --free NAME,NAME, or %s --clean to be asked about each.\n' \
                "$PROGNAME" "$PROGNAME" "$PROGNAME"
        fi
    fi
    printf 'The full report: %s\n' "$PROGNAME"
}

# notify_send <subject> <body file> <level>: every configured channel. Succeeds
# when at least one channel delivered the message.
notify_send() {
    local subject="$1" body="$2" level="$3" sent=0 hermes errf
    errf=$(mktemp "${TMPDIR:-/tmp}/vpsusagecheck-notify.XXXXXX") || return 1
    CLEANUP_PATHS+=("$errf")
    if [ -n "$NOTIFY_HERMES_TO" ]; then
        if ! hermes=$(find_hermes); then
            warn "notification: hermes not found (set HERMES_BIN)"
        elif without_locks run_limited 60 "$hermes" send --to "$NOTIFY_HERMES_TO" --quiet \
                --subject "$subject" --file "$body" > /dev/null 2> "$errf"; then
            sent=1
        else
            warn "notification: hermes send failed: $(head -c 300 "$errf" | tr '\n' ' ')"
        fi
    fi
    if [ -n "$NOTIFY_COMMAND" ]; then
        if without_locks run_limited 60 env NOTIFY_SUBJECT="$subject" NOTIFY_BODY_FILE="$body" \
                NOTIFY_LEVEL="$level" NOTIFY_HOST="$(hostname)" \
                sh -c "$NOTIFY_COMMAND" > /dev/null 2> "$errf"; then
            sent=1
        else
            warn "notification: NOTIFY_COMMAND failed: $(head -c 300 "$errf" | tr '\n' ' ')"
        fi
    fi
    [ "$sent" -eq 1 ]
}

# notify_body_file <kind> <new keys>: writes the digest to a temporary file,
# shortened to what a Telegram message holds, and prints its path.
notify_body_file() {
    local body
    body=$(mktemp "${TMPDIR:-/tmp}/vpsusagecheck-body.XXXXXX") || return 1
    CLEANUP_PATHS+=("$body")
    notify_digest "$1" "$2" > "$body"
    if [ "$(wc -c < "$body")" -gt "$NOTIFY_MAX_CHARS" ]; then
        { head -c "$((NOTIFY_MAX_CHARS - 80))" "$body"
          printf '\n(shortened; run %s for the full report)\n' "$PROGNAME"; } > "$body.short"
        mv -f -- "$body.short" "$body"
    fi
    printf '%s' "$body"
}

notify_decide() {
    local statef="$STATE_DIR/notify.state" cur prev="" prev_epoch=0 now newk kind=""
    local repeat level body
    now=$(date +%s)
    cur=$(current_alert_keys)
    if [ -s "$statef" ]; then
        prev_epoch=$(awk 'NR == 1 {printf "%.0f", $1}' "$statef")
        is_number "$prev_epoch" || prev_epoch=0
        prev=$(awk 'NR > 1 && NF' "$statef")
    fi
    newk=$(comm -23 <(printf '%s\n' "$cur" | sed '/^$/d') <(printf '%s\n' "$prev" | sed '/^$/d'))
    repeat=$(awk -v h="$NOTIFY_REPEAT_HOURS" 'BEGIN {printf "%.0f", h * 3600 - 900}')

    if [ -n "$cur" ]; then
        if [ -n "$newk" ]; then
            kind="alert"
        elif [ $((now - prev_epoch)) -ge "$repeat" ]; then
            kind="reminder"
        fi
    elif [ -n "$prev" ] && [ "$NOTIFY_RECOVERY" = "1" ]; then
        kind="recovery"
    fi

    if [ -z "$kind" ]; then
        # Nothing to say. Still remember a shrunken set, so that an issue which
        # went away and comes back is reported as new.
        if [ "$cur" != "$prev" ]; then
            { printf '%s\n' "$prev_epoch"; [ -n "$cur" ] && printf '%s\n' "$cur"; } \
                | atomic_replace "$statef"
        fi
        return 0
    fi

    level="ok"
    [ -n "$cur" ] && level=$(printf '%s\n' "$cur" | awk -F: '
        {r = ($1 == "critical") ? 3 : ($1 == "warning") ? 2 : 1; if (r > best) {best = r; name = $1}}
        END {print name}')
    body=$(notify_body_file "$kind" "$newk") || return 1
    if notify_send "$(notify_subject "$kind" "$newk")" "$body" "$level"; then
        { printf '%s\n' "$now"; [ -n "$cur" ] && printf '%s\n' "$cur"; } | atomic_replace "$statef"
    fi
    return 0
}

notify_maybe() {
    if ! notify_configured; then
        warn "--notify: no channel configured (set NOTIFY_HERMES_TO or NOTIFY_COMMAND)"
        return 0
    fi
    if [ "$STATE_OK" -ne 1 ]; then
        warn "--notify: cannot write to $STATE_DIR, so repeated alerts could not be held back; nothing sent"
        return 0
    fi
    with_lock state.lock 10 notify_decide
    return 0
}

notify_test() {
    local body
    if ! notify_configured; then
        warn "--notify-test: no channel configured (set NOTIFY_HERMES_TO or NOTIFY_COMMAND)"
        exit "$EXIT_USAGE"
    fi
    body=$(notify_body_file test "") || exit "$EXIT_WARNING"
    if notify_send "$(notify_subject test "")" "$body" test; then
        printf 'Test message sent.\n'
        exit "$EXIT_OK"
    fi
    exit "$EXIT_WARNING"
}

# ---------------------------------------------------------------------------
# Text rendering
# ---------------------------------------------------------------------------
readonly BOX_WIDTH=66

section_rule() { printf '%s%s%s\n' "$BLUE" "$(repeat_char '-' $((BOX_WIDTH + 2)))" "$NC"; }

box_centered() {
    local text="$1" len pad_left pad_right
    len=${#text}
    if [ "$len" -gt "$BOX_WIDTH" ]; then
        text="${text:0:$BOX_WIDTH}"
        len=$BOX_WIDTH
    fi
    pad_left=$(( (BOX_WIDTH - len) / 2 ))
    pad_right=$(( BOX_WIDTH - len - pad_left ))
    printf '%s|%s%s%s|%s\n' "$BOLD$BLUE" \
        "$(repeat_char ' ' "$pad_left")" "$text" "$(repeat_char ' ' "$pad_right")" "$NC"
}

render_header() {
    local border
    border=$(repeat_char '=' "$BOX_WIDTH")
    printf '%s+%s+%s\n' "$BOLD$BLUE" "$border" "$NC"
    box_centered "VPS USAGE CHECK v${VERSION}"
    printf '%s+%s+%s\n' "$BOLD$BLUE" "$border" "$NC"
    printf '%sGenerated:%s %s\n' "$CYAN" "$NC" "$(date)"
    printf '%sHostname:%s  %s\n' "$CYAN" "$NC" "$(hostname)"
    [ -n "$CONFIG_FILE" ] && printf '%sConfig:%s    %s\n' "$CYAN" "$NC" "$CONFIG_FILE"
    printf '\n'
}

render_network() {
    printf '%s%s[NET] NETWORK TRAFFIC (%s, %sTB monthly limit)%s\n' \
        "$BOLD" "$GREEN" "$BANDWIDTH_COUNT_MODE" "$BANDWIDTH_LIMIT_TB" "$NC"
    section_rule

    printf '  %sInterface:%s     %s  %s(source: %s)%s\n' \
        "$YELLOW" "$NC" "${NET_IFACE:-unknown}" "$CYAN" "$NET_SOURCE" "$NC"

    if [ -n "$NET_COUNTED" ]; then
        printf '  %sMonth inbound:%s  %s\n'  "$YELLOW" "$NC" "$(bytes_to_human "$NET_RX")"
        printf '  %sMonth outbound:%s %s\n'  "$YELLOW" "$NC" "$(bytes_to_human "$NET_TX")"
        printf '  %sMetered usage:%s  %s of %sTB  (%s%%)\n' \
            "$CYAN" "$NC" "$(bytes_to_human "$NET_COUNTED")" \
            "$BANDWIDTH_LIMIT_TB" "$NET_PCT"

        if [ -n "$NET_PROJECTED" ]; then
            local colour="$GREEN"
            compare_gt "$NET_PROJECTED_PCT" 80  && colour="$YELLOW"
            compare_gt "$NET_PROJECTED_PCT" 100 && colour="$RED"
            printf '  %sMonth-end est.:%s %s%s (%s%% of cap)%s\n' \
                "$CYAN" "$NC" "$colour" "$(bytes_to_human "$NET_PROJECTED")" \
                "$NET_PROJECTED_PCT" "$NC"
        fi
    else
        printf '  %sNo month-to-date data available.%s\n' "$RED" "$NC"
        printf '  %sInstall vnstat (apt install vnstat) for reliable cap tracking.%s\n' \
            "$YELLOW" "$NC"
    fi

    if [ -n "$NET_BOOT_RX" ]; then
        printf '  %sSince boot:%s     rx %s / tx %s' \
            "$BLUE" "$NC" "$(bytes_to_human "$NET_BOOT_RX")" "$(bytes_to_human "$NET_BOOT_TX")"
        if command_exists uptime && uptime -p >/dev/null 2>&1; then
            printf '  (%s)' "$(uptime -p)"
        fi
        printf '\n'
    fi
    printf '\n'
}

render_memory() {
    printf '%s%s[MEM] MEMORY USAGE%s\n' "$BOLD" "$GREEN" "$NC"
    section_rule
    if [ -z "$MEM_TOTAL_KB" ]; then
        printf '  %sMemory information not available.%s\n\n' "$RED" "$NC"
        return
    fi
    printf '  %sTotal:%s     %s\n'          "$YELLOW" "$NC" "$(kb_to_human "$MEM_TOTAL_KB")"
    printf '  %sUsed:%s      %s (%s%%)\n'   "$YELLOW" "$NC" "$(kb_to_human "$MEM_USED_KB")" "$MEM_PCT"
    printf '  %sAvailable:%s %s\n'          "$YELLOW" "$NC" "$(kb_to_human "$MEM_AVAIL_KB")"
    if [ -n "$SWAP_TOTAL_KB" ]; then
        printf '  %sSwap:%s      %s of %s (%s%%)\n' "$PURPLE" "$NC" \
            "$(kb_to_human "$SWAP_USED_KB")" "$(kb_to_human "$SWAP_TOTAL_KB")" "$SWAP_PCT"
    fi
    printf '\n'
}

render_load() {
    printf '%s%s[CPU] SYSTEM LOAD%s\n' "$BOLD" "$GREEN" "$NC"
    section_rule
    if [ -z "$LOAD_1" ]; then
        printf '  %sLoad information not available.%s\n\n' "$RED" "$NC"
        return
    fi
    printf '  %sLoad average:%s %s (1m) | %s (5m) | %s (15m)\n' \
        "$YELLOW" "$NC" "$LOAD_1" "$LOAD_5" "$LOAD_15"
    printf '  %sCPU cores:%s    %s\n'            "$YELLOW" "$NC" "$CPU_CORES"
    printf '  %sLoad:%s         %s%% of capacity\n' "$YELLOW" "$NC" "$LOAD_PCT"
    printf '  %sCPU usage:%s    %s%% (1s sample)\n' "$CYAN" "$NC" "$CPU_USAGE"
    printf '\n'
}

render_disk() {
    printf '%s%s[DSK] DISK USAGE%s\n' "$BOLD" "$GREEN" "$NC"
    section_rule
    if [ ${#DISK_ROWS[@]} -eq 0 ]; then
        printf '  %sNo reportable filesystems.%s\n\n' "$YELLOW" "$NC"
        return
    fi

    local row mount size used pct level marker colour shown
    for row in "${DISK_ROWS[@]}"; do
        IFS='|' read -r mount _ _ size used _ pct level <<<"$row"
        case "$level" in
            critical) colour="$RED";    marker="CRITICAL" ;;
            warning)  colour="$RED";    marker="WARNING"  ;;
            notice)   colour="$YELLOW"; marker="NOTICE"   ;;
            *)        colour="";        marker=""         ;;
        esac
        if [ -n "$pct" ]; then shown="${pct}%"; else shown="n/a"; fi
        printf '  %s%-24s%s %9s used of %-9s %5s' \
            "$YELLOW" "$mount" "$NC" \
            "$(kb_to_human "$used")" "$(kb_to_human "$size")" "$shown"
        [ -n "$marker" ] && printf '  %s%s%s' "$colour" "$marker" "$NC"
        printf '\n' 
    done

    for row in ${INODE_ROWS[@]+"${INODE_ROWS[@]}"}; do
        IFS='|' read -r mount _ _ _ pct level <<<"$row"
        colour="$YELLOW"; [ "$level" = "warning" ] && colour="$RED"
        printf '  %sinodes %-17s%s %s%% used %s%s%s\n' \
            "$YELLOW" "$mount" "$NC" "$pct" "$colour" "${level^^}" "$NC"
    done
    printf '\n'
}

render_disk_analysis() {
    printf '%s%s[SPC] DISK SPACE: FORECAST AND SAVINGS%s\n' "$BOLD" "$GREEN" "$NC"
    section_rule

    local row mount state slope pace days n span level colour when now line
    now=$(date +%s)

    # Forecast, one line per filesystem.
    if [ "$STATE_OK" -ne 1 ]; then
        printf '  %sForecast off:%s cannot write to %s\n' "$YELLOW" "$NC" "$STATE_DIR"
    elif [ ${#TREND_ROWS[@]} -gt 0 ]; then
        printf '  %sForecast%s (fitted over the last %s days):\n' "$CYAN" "$NC" "$DISK_TREND_DAYS"
        for row in "${TREND_ROWS[@]}"; do
            IFS='|' read -r mount state slope pace days n span level <<<"$row"
            case "$level" in
                critical|warning) colour="$RED" ;;
                notice)           colour="$YELLOW" ;;
                *)                colour="" ;;
            esac
            printf '    %s%-20s%s ' "$YELLOW" "$mount" "$NC"
            case "$state" in
                collecting)
                    printf 'collecting history (%s over %s h; a forecast needs %s h)\n' \
                        "$(plural "$n" sample samples)" "$span" "$TREND_MIN_SPAN_HOURS"
                    ;;
                growing)
                    if compare_gt "$days" 365; then
                        printf '%s a day; more than a year of space left at this pace\n' \
                            "$(signed_kb_to_human "$slope")"
                    else
                        when=$(date -d "@$(awk -v d="$days" -v n="$now" 'BEGIN {printf "%.0f", n + d * 86400}')" \
                            '+%-d %b' 2>/dev/null)
                        printf '%s%s a day; full in %s, around %s%s' "$colour" \
                            "$(signed_kb_to_human "$slope")" "$(days_phrase "$days")" "$when" "$NC"
                        [ "$level" != "ok" ] && printf '  %s%s%s' "$colour" "${level^^}" "$NC"
                        printf '\n'
                    fi
                    ;;
                steady)    printf 'steady (%s a day)\n' "$(signed_kb_to_human "$slope")" ;;
                shrinking) printf 'not growing (%s a day)\n' "$(signed_kb_to_human "$slope")" ;;
            esac
        done
    fi

    # The folder scan.
    case "$SCAN_STATUS" in
        disabled)
            printf '  %sFolder scan:%s off (DISK_SCAN=0)\n\n' "$YELLOW" "$NC"
            return
            ;;
        none)
            if [ -z "$SCAN_NOTE" ]; then
                printf '  %sFolder scan:%s none yet; run %s --scan (it can take a few minutes)\n' \
                    "$YELLOW" "$NC" "$PROGNAME"
            else
                printf '  %sFolder scan:%s\n' "$YELLOW" "$NC"
            fi
            ;;
        *)
            local age=""
            is_number "$SCAN_FINISHED" && age=$(human_age $((now - SCAN_FINISHED)))
            printf '  %sFolder scan:%s %s, %s (%s)\n' "$CYAN" "$NC" "${age:-at an unknown time}" \
                "$SCAN_STATUS" "$SCAN_ROOTS"
            ;;
    esac
    [ -n "$SCAN_NOTE" ] && printf '    %s%s%s\n' "$YELLOW" "$SCAN_NOTE" "$NC"
    local scanned used
    for row in ${COVERAGE_ROWS[@]+"${COVERAGE_ROWS[@]}"}; do
        IFS='|' read -r mount scanned used <<<"$row"
        printf '    The scanned folders hold %s of the %s used on %s.\n' \
            "$(kb_to_human "$scanned")" "$(kb_to_human "$used")" "$mount"
    done
    if is_number "$SCAN_UNREADABLE" && [ "$SCAN_UNREADABLE" -gt 0 ]; then
        printf '    %s could not be read by %s; run as root to include them.\n' \
            "$(plural "$SCAN_UNREADABLE" folder folders)" "$ME"
    fi
    if is_number "$SCAN_SKIPPED" && [ "$SCAN_SKIPPED" -gt 0 ]; then
        printf '    %s with control characters in the name left out.\n' \
            "$(plural "$SCAN_SKIPPED" path paths)"
    fi

    local kb change path pct fs_size mtime
    if [ ${#DIR_TOP_ROWS[@]} -gt 0 ]; then
        printf '  %sLargest folders:%s\n' "$CYAN" "$NC"
        for line in "${DIR_TOP_ROWS[@]}"; do
            IFS=$'\t' read -r kb change path <<<"$line"
            fs_size=$(disk_row_field "$(mount_of_path "$path")" 4)
            pct=$(awk -v k="$kb" -v s="${fs_size:-0}" 'BEGIN {if (s > 0) printf "%.0f%%", k / s * 100; else printf "-"}')
            printf '    %10s %4s  %s' "$(kb_to_human "$kb")" "$pct" "$path"
            if [ "$change" != "-" ] && is_number "$change" && [ "${change#-}" -ge 1024 ]; then
                printf '  %s(%s)%s' "$CYAN" "$(signed_kb_to_human "$change")" "$NC"
            fi
            printf '\n'
        done
    fi

    if [ ${#GROW_ROWS[@]} -gt 0 ]; then
        printf '  %sGrowing fastest since %s:%s\n' "$CYAN" \
            "$(date -d "@${GROWTH_SINCE:-0}" '+%-d %b' 2>/dev/null)" "$NC"
        for line in "${GROW_ROWS[@]}"; do
            IFS=$'\t' read -r kb path <<<"$line"
            printf '    %10s  %s\n' "$(signed_kb_to_human "$kb")" "$path"
        done
    fi

    if [ ${#BIGFILE_ROWS[@]} -gt 0 ]; then
        printf '  %sLarge files:%s\n' "$CYAN" "$NC"
        for line in "${BIGFILE_ROWS[@]}"; do
            IFS=$'\t' read -r kb mtime path <<<"$line"
            printf '    %10s  %s  %s\n' "$(kb_to_human "$kb")" \
                "$(date -d "@$mtime" +%F 2>/dev/null)" "$path"
        done
    fi

    # Savings, safe ones first.
    local category safety command note heading action
    for safety in safe review; do
        if [ "$safety" = "safe" ]; then
            [ "$SAVINGS_SAFE_KB" -gt 0 ] || continue
            heading="Can be freed safely, about $(kb_to_human "$SAVINGS_SAFE_KB"):"
        else
            [ "$SAVINGS_REVIEW_KB" -gt 0 ] || continue
            heading="Worth reviewing, about $(kb_to_human "$SAVINGS_REVIEW_KB"):"
        fi
        printf '  %s%s%s\n' "$CYAN" "$heading" "$NC"
        for line in ${SAVING_ROWS[@]+"${SAVING_ROWS[@]}"}; do
            IFS=$'\t' read -r kb category state action path command note <<<"$line"
            [ "$state" = "$safety" ] || continue
            if [ "$safety" = "safe" ]; then
                printf '    %10s  %s  %s[%s]%s\n' "$(kb_to_human "$kb")" "$category" \
                    "$CYAN" "$(saving_id "$action" "$path")" "$NC"
            else
                printf '    %10s  %s\n' "$(kb_to_human "$kb")" "$category"
            fi
            printf '                %s\n' "$note"
            [ "$command" != "-" ] && printf '                %s%s%s\n' "$YELLOW" "$command" "$NC"
        done
    done

    if [ ${#DELETED_ROWS[@]} -gt 0 ]; then
        local pid process
        printf '  %sDeleted files still held open, %s (restarting the program releases the space):%s\n' \
            "$CYAN" "$(kb_to_human "$DELETED_KB")" "$NC"
        for line in "${DELETED_ROWS[@]}"; do
            IFS=$'\t' read -r kb pid process path <<<"$line"
            printf '    %10s  %s (pid %s)  %s\n' "$(kb_to_human "$kb")" "$process" "$pid" "$path"
        done
    fi

    if [ "$SAVINGS_SAFE_KB" -gt 0 ]; then
        printf '  To free the safe items one at a time, with a question before each: %s%s --clean%s\n' \
            "$BOLD" "$PROGNAME" "$NC"
        printf '  Without questions: %s --free NAME,NAME (names in brackets) or %s --clean --yes\n' \
            "$PROGNAME" "$PROGNAME"
    fi
    printf '\n'
}

render_status() {
    printf '%s%s[SYS] SYSTEM STATUS%s\n' "$BOLD" "$GREEN" "$NC"
    section_rule

    if [ -n "$MUNIN_CRITICAL" ]; then
        printf '  %sMunin plugins:%s critical %s | warning %s | unknown %s\n' \
            "$YELLOW" "$NC" "$MUNIN_CRITICAL" "$MUNIN_WARNING" "$MUNIN_UNKNOWN"
    fi

    if [ "${SERVICES_TOTAL:-0}" -eq 0 ]; then
        printf '  %sServices:%s      no known service manager detected\n' "$YELLOW" "$NC"
    else
        printf '  %sServices:%s      %s/%s running' \
            "$YELLOW" "$NC" "$SERVICES_OK" "$SERVICES_TOTAL"
        [ ${#SERVICES_DOWN[@]} -gt 0 ] && printf ' %s(down: %s)%s' "$RED" "${SERVICES_DOWN[*]}" "$NC"
        printf '\n'
    fi

    if [ -n "$FAILED_UNITS" ]; then
        if [ "$FAILED_UNITS" -gt 0 ]; then
            printf '  %sFailed units:%s  %s%s%s' \
                "$YELLOW" "$NC" "$RED" "${FAILED_UNIT_NAMES[*]}" "$NC"
        else
            printf '  %sFailed units:%s  none' "$YELLOW" "$NC"
        fi
        [ ${#IGNORED_UNIT_NAMES[@]} -gt 0 ] && printf ' (ignored: %s)' "${IGNORED_UNIT_NAMES[*]}"
        printf '\n'
    fi

    [ "$REBOOT_REQUIRED" != "unknown" ] && \
        printf '  %sReboot needed:%s %s\n' "$YELLOW" "$NC" "$REBOOT_REQUIRED"

    if [ -n "$UPDATES_TOTAL" ]; then
        printf '  %sUpdates:%s       %s pending' "$YELLOW" "$NC" "$UPDATES_TOTAL"
        [ -n "$UPDATES_SECURITY" ] && printf ' (%s security)' "$UPDATES_SECURITY"
        printf '\n'
    fi

    if command_exists uptime && uptime -p >/dev/null 2>&1; then
        printf '  %sUptime:%s        %s\n' "$YELLOW" "$NC" "$(uptime -p)"
    fi
    printf '\n'
}

render_top_processes() {
    [ ${#TOP_MEM_ROWS[@]} -gt 0 ] || return 0
    printf '%s%s[TOP] TOP CONSUMERS%s\n' "$BOLD" "$PURPLE" "$NC"
    section_rule
    local row mem cpu comm
    printf '  %sBy memory:%s\n' "$CYAN" "$NC"
    for row in ${TOP_MEM_ROWS[@]+"${TOP_MEM_ROWS[@]}"}; do
        read -r mem cpu comm <<<"$row"
        printf '    %-24s mem %5s%%  cpu %5s%%\n' "$comm" "$mem" "$cpu"
    done
    printf '  %sBy CPU:%s\n' "$CYAN" "$NC"
    for row in ${TOP_CPU_ROWS[@]+"${TOP_CPU_ROWS[@]}"}; do
        read -r mem cpu comm <<<"$row"
        printf '    %-24s mem %5s%%  cpu %5s%%\n' "$comm" "$mem" "$cpu"
    done
    printf '\n'
}

# ---------------------------------------------------------------------------
# Summary: one line per check
# ---------------------------------------------------------------------------
# Each line gives the verdict, the name of the check, the measured values and,
# in parentheses, the thresholds they are held against. The verdict is read
# from the recorded issues rather than worked out a second time, so that the
# summary, the exit code and the alerts cannot disagree. OFF marks a check
# switched off by a setting, N/A a check with nothing to measure here.
SUMMARY_LEVEL=""
declare -A SUMMARY_CLAIMED=()

# summary_level <pattern...>: sets SUMMARY_LEVEL to the highest level among the
# issues whose key matches one of the shell patterns ("" when none does) and
# marks those issues as shown. It sets a variable instead of printing, since a
# command substitution would run it in a subshell and lose the marks.
summary_level() {
    local i key pattern level rank best_rank=0
    SUMMARY_LEVEL=""
    for i in ${ISSUES[@]+"${!ISSUES[@]}"}; do
        key="${ISSUE_KEYS[$i]}"
        for pattern in "$@"; do
            # The unquoted right-hand side is deliberate: it is a pattern.
            # shellcheck disable=SC2053
            [[ $key == $pattern ]] || continue
            SUMMARY_CLAIMED[$i]=1
            level="${ISSUES[$i]%%|*}"
            rank=$(level_rank "$level")
            if [ "$rank" -gt "$best_rank" ]; then
                best_rank=$rank
                SUMMARY_LEVEL=$level
            fi
            break
        done
    done
    return 0
}

# summary_line <verdict> <name> <text>; the verdict is ok, notice, warning,
# critical, off or n/a.
summary_line() {
    local label colour
    case "$1" in
        critical) label="CRITICAL"; colour="$RED$BOLD" ;;
        warning)  label="WARNING";  colour="$RED" ;;
        notice)   label="NOTICE";   colour="$YELLOW" ;;
        off)      label="OFF";      colour="$CYAN" ;;
        n/a)      label="N/A";      colour="$CYAN" ;;
        *)        label="OK";       colour="$GREEN" ;;
    esac
    printf '  %s%-8s%s  %-13s %s\n' "$colour" "$label" "$NC" "$2" "$3"
}

# join_words <word...>: "a", "a and b", "a, b and c".
join_words() {
    local out="" i n=$#
    for ((i = 1; i <= n; i++)); do
        if [ "$i" -eq 1 ]; then out="${!i}"
        elif [ "$i" -eq "$n" ]; then out+=" and ${!i}"
        else out+=", ${!i}"
        fi
    done
    printf '%s' "$out"
}

# issue_key_present <key>: true when an issue with exactly this key was recorded.
issue_key_present() {
    local key
    for key in ${ISSUE_KEYS[@]+"${ISSUE_KEYS[@]}"}; do
        [ "$key" = "$1" ] && return 0
    done
    return 1
}

# span_phrase <hours>: "7 days", "20 h".
span_phrase() {
    awk -v h="${1:-0}" 'BEGIN {
        if (h >= 36) printf "%.0f days", h / 24
        else         printf "%.0f h", h
    }'
}

summary_bandwidth() {
    local text what
    summary_level bandwidth 'bandwidth-*'
    if [ -z "$NET_COUNTED" ]; then
        text="no month-to-date counter, so the cap cannot be checked (install vnstat)"
        if [ -n "$NET_BOOT_TX" ]; then
            text+="; since boot $(bytes_to_human "$NET_BOOT_RX") in, $(bytes_to_human "$NET_BOOT_TX") out"
        fi
        summary_line "${SUMMARY_LEVEL:-notice}" Bandwidth "$text"
        return
    fi
    case "$BANDWIDTH_COUNT_MODE" in
        in)  what="received" ;;
        sum) what="in and out" ;;
        max) what="in the busier direction" ;;
        *)   what="sent" ;;
    esac
    text="$(bytes_to_human "$NET_COUNTED") $what, ${NET_PCT}% of ${BANDWIDTH_LIMIT_TB} TB"
    text+=" (notice >${BANDWIDTH_NOTICE_PCT}%, warning >${BANDWIDTH_WARN_PCT}%)"
    if [ -n "$NET_PROJECTED_PCT" ]; then
        text+="; month end ${NET_PROJECTED_PCT}% (warning >100%)"
    fi
    summary_line "${SUMMARY_LEVEL:-ok}" Bandwidth "$text"
}

summary_memory() {
    summary_level memory
    if [ -z "$MEM_PCT" ]; then
        summary_line n/a Memory "no memory figures (/proc/meminfo unreadable)"
        return
    fi
    summary_line "${SUMMARY_LEVEL:-ok}" Memory \
        "$(kb_to_human "$MEM_USED_KB") of $(kb_to_human "$MEM_TOTAL_KB") in use, ${MEM_PCT}% (notice >${MEMORY_NOTICE_PCT}%, warning >${MEMORY_WARN_PCT}%)"
}

summary_swap() {
    summary_level swap
    if [ -n "$SWAP_TOTAL_KB" ]; then
        summary_line "${SUMMARY_LEVEL:-ok}" Swap \
            "$(kb_to_human "$SWAP_USED_KB") of $(kb_to_human "$SWAP_TOTAL_KB") in use, ${SWAP_PCT}% (notice >${SWAP_NOTICE_PCT}%, warning >${SWAP_WARN_PCT}%)"
    elif [ -n "$MEM_PCT" ]; then
        summary_line n/a Swap "no swap space on this machine"
    else
        summary_line n/a Swap "no memory figures (/proc/meminfo unreadable)"
    fi
}

summary_load() {
    local warn_pct
    summary_level load
    if [ -z "$LOAD_1" ]; then
        summary_line n/a Load "no load figures (/proc/loadavg unreadable)"
        return
    fi
    # The warning compares the load with cores x LOAD_WARN_MULTIPLIER, that is
    # the capacity with 100 x LOAD_WARN_MULTIPLIER per cent.
    warn_pct=$(awk -v m="$LOAD_WARN_MULTIPLIER" 'BEGIN {printf "%g", m * 100}')
    summary_line "${SUMMARY_LEVEL:-ok}" Load \
        "1-minute load ${LOAD_1} on $(plural "$CPU_CORES" core cores), ${LOAD_PCT}% of capacity (notice >${LOAD_NOTICE_PCT}%, warning >${warn_pct}%)"
}

summary_disk_space() {
    local row mount pct level entries=""
    summary_level 'disk-full:*'
    if [ ${#DISK_ROWS[@]} -eq 0 ]; then
        summary_line n/a "Disk space" "no filesystem to check"
        return
    fi
    for row in "${DISK_ROWS[@]}"; do
        IFS='|' read -r mount _ _ _ _ _ pct level <<<"$row"
        entries+="${entries:+, }$mount ${pct:-n/a}${pct:+%}"
        [ "$level" != "ok" ] && entries+=" ($level)"
    done
    summary_line "${SUMMARY_LEVEL:-ok}" "Disk space" \
        "$entries (notice >${DISK_NOTICE_PCT}%, warning >${DISK_WARN_PCT}%, critical >${DISK_CRITICAL_PCT}%)"
}

summary_inodes() {
    local row mount pct level entries=""
    summary_level 'inodes:*'
    if [ ${#INODE_ALL[@]} -eq 0 ]; then
        summary_line n/a Inodes "no filesystem counts inodes"
        return
    fi
    for row in "${INODE_ALL[@]}"; do
        IFS='|' read -r mount pct level <<<"$row"
        entries+="${entries:+, }$mount ${pct}%"
        [ "$level" != "ok" ] && entries+=" ($level)"
    done
    summary_line "${SUMMARY_LEVEL:-ok}" Inodes \
        "$entries (notice >${INODE_NOTICE_PCT}%, warning >${INODE_WARN_PCT}%)"
}

summary_disk_growth() {
    local row mount state slope pace days span text when limits
    local total=0 growing=0 collecting=0 first="" first_days="" first_slope="" span_max=0
    limits="(notice <${DISK_FILL_NOTICE_DAYS} days left, warning <${DISK_FILL_WARN_DAYS}, critical <${DISK_FILL_CRITICAL_DAYS})"
    summary_level 'disk-fill:*' 'disk-burst:*'
    if [ "$STATE_OK" -ne 1 ]; then
        summary_line off "Disk growth" "no history kept: cannot write to $STATE_DIR"
        return
    fi
    for row in ${TREND_ROWS[@]+"${TREND_ROWS[@]}"}; do
        IFS='|' read -r mount state slope _ days _ span _ <<<"$row"
        total=$((total + 1))
        case "$state" in
            collecting)
                collecting=$((collecting + 1))
                continue
                ;;
            growing)
                growing=$((growing + 1))
                if [ -z "$first" ] || compare_gt "$first_days" "$days"; then
                    first="$mount" first_days="$days" first_slope="$slope"
                fi
                ;;
        esac
        compare_gt "$span" "$span_max" && span_max="$span"
    done
    if [ "$total" -eq 0 ]; then
        summary_line n/a "Disk growth" "no history yet"
        return
    fi
    if [ "$collecting" -eq "$total" ]; then
        summary_line n/a "Disk growth" \
            "collecting history; a forecast needs ${TREND_MIN_SPAN_HOURS} h of it"
        return
    fi
    if [ "$growing" -gt 0 ]; then
        text="$first grows by $(kb_to_human "$first_slope") a day"
        if compare_gt "$first_days" 365; then
            text+=", more than a year of space left"
        else
            when=$(date -d "@$(awk -v d="$first_days" -v n="$(date +%s)" \
                'BEGIN {printf "%.0f", n + d * 86400}')" '+%-d %b' 2>/dev/null)
            text+=", full in $(days_phrase "$first_days")${when:+ (around $when)}"
        fi
        [ "$growing" -gt 1 ] && text+=", $((growing - 1)) more growing"
    else
        text="nothing filling up over the last $(span_phrase "$span_max")"
        [ "$collecting" -gt 0 ] && text+=", $collecting still collecting history"
    fi
    for row in ${TREND_ROWS[@]+"${TREND_ROWS[@]}"}; do
        IFS='|' read -r mount _ _ pace _ <<<"$row"
        if issue_key_present "disk-burst:$mount"; then
            text+="; $mount grew by $(kb_to_human "$pace") in the last 24 h"
        fi
    done
    summary_line "${SUMMARY_LEVEL:-ok}" "Disk growth" "$text $limits"
}

summary_reclaimable() {
    local line safety safe_count=0 age="" text scan
    summary_level disk-reclaimable
    case "$SCAN_STATUS" in
        disabled)
            summary_line off Reclaimable "folder scan off (DISK_SCAN=0)"
            return
            ;;
        none)
            summary_line n/a Reclaimable "no folder scan yet (run $PROGNAME --scan)"
            return
            ;;
    esac
    for line in ${SAVING_ROWS[@]+"${SAVING_ROWS[@]}"}; do
        IFS=$'\t' read -r _ _ safety _ <<<"$line"
        [ "$safety" = "safe" ] && safe_count=$((safe_count + 1))
    done
    if [ "$SAVINGS_SAFE_KB" -gt 0 ]; then
        text="$(kb_to_human "$SAVINGS_SAFE_KB") safe in $(plural "$safe_count" item items)"
    else
        text="nothing safe to free"
    fi
    [ "$SAVINGS_REVIEW_KB" -gt 0 ] && text+=", $(kb_to_human "$SAVINGS_REVIEW_KB") to review"
    is_number "$SCAN_FINISHED" && age=$(human_age $(( $(date +%s) - SCAN_FINISHED )))
    scan="scan ${age:-of unknown age}"
    [ "$SCAN_STATUS" = "complete" ] || scan+=", $SCAN_STATUS"
    summary_line "${SUMMARY_LEVEL:-ok}" Reclaimable \
        "$text, $scan (notice from ${DISK_RECLAIM_NOTICE_GB} GB safe)"
}

summary_deleted() {
    local who top_pid top_comm text
    summary_level deleted-open
    if [ "$EUID" -eq 0 ]; then who="any program"; else who="the programs of $ME"; fi
    if [ "${DELETED_KB:-0}" -gt 0 ]; then
        text="$(kb_to_human "$DELETED_KB") held open by $who"
        if [ ${#DELETED_ROWS[@]} -gt 0 ]; then
            IFS=$'\t' read -r _ top_pid top_comm _ <<<"${DELETED_ROWS[0]}"
            text+=", most by $top_comm (pid $top_pid)"
        fi
    else
        text="none held open by $who"
    fi
    summary_line "${SUMMARY_LEVEL:-ok}" "Deleted files" \
        "$text (notice from $(kb_to_human "$DELETED_OPEN_NOTICE_KB"))"
}

summary_munin() {
    summary_level munin
    if [ -z "$MUNIN_CRITICAL" ]; then
        summary_line n/a Munin "no problems page to read (needs Munin and w3m)"
        return
    fi
    summary_line "${SUMMARY_LEVEL:-ok}" Munin \
        "${MUNIN_CRITICAL} critical, ${MUNIN_WARNING} warning, ${MUNIN_UNKNOWN} unknown plugin states"
}

summary_services() {
    local name text down=" "
    local -a up=()
    summary_level 'service:*'
    if [ "${SERVICES_TOTAL:-0}" -eq 0 ]; then
        summary_line n/a Services "neither ssh nor cron found"
        return
    fi
    for name in ${SERVICES_DOWN[@]+"${SERVICES_DOWN[@]}"}; do down+="$name "; done
    for name in ${SERVICES_CHECKED[@]+"${SERVICES_CHECKED[@]}"}; do
        case "$down" in *" $name "*) ;; *) up+=("$name") ;; esac
    done
    if [ ${#SERVICES_DOWN[@]} -gt 0 ]; then
        text="$(join_words "${SERVICES_DOWN[@]}") not running"
        [ ${#up[@]} -gt 0 ] && text+=", $(join_words "${up[@]}") running"
    else
        text="$(join_words ${up[@]+"${up[@]}"}) running"
    fi
    summary_line "${SUMMARY_LEVEL:-ok}" Services "$text"
}

summary_failed_units() {
    local text
    summary_level 'failed-units:*'
    if [ "$CHECK_FAILED_UNITS" != "1" ]; then
        summary_line off "Failed units" "check off (CHECK_FAILED_UNITS=0)"
        return
    fi
    if [ -z "$FAILED_UNITS" ]; then
        summary_line n/a "Failed units" "no systemd on this machine"
        return
    fi
    if [ "$FAILED_UNITS" -gt 0 ]; then
        text="$(plural "$FAILED_UNITS" unit units) failed: ${FAILED_UNIT_NAMES[*]}"
    else
        text="none"
    fi
    [ ${#IGNORED_UNIT_NAMES[@]} -gt 0 ] && text+=" (ignored: ${IGNORED_UNIT_NAMES[*]})"
    summary_line "${SUMMARY_LEVEL:-ok}" "Failed units" "$text"
}

summary_reboot() {
    summary_level reboot
    case "$REBOOT_REQUIRED" in
        yes) summary_line "${SUMMARY_LEVEL:-notice}" Reboot "needed to finish applying updates" ;;
        no)  summary_line "${SUMMARY_LEVEL:-ok}" Reboot "not needed" ;;
        *)   summary_line off Reboot "check off (CHECK_REBOOT_REQUIRED=0)" ;;
    esac
}

summary_updates() {
    local text
    summary_level security-updates
    if [ "$CHECK_UPDATES" != "1" ]; then
        summary_line off Updates "check off (CHECK_UPDATES=0)"
        return
    fi
    if [ -z "$UPDATES_TOTAL" ]; then
        summary_line n/a Updates "no update information (apt-check unavailable)"
        return
    fi
    if [ "$UPDATES_TOTAL" -eq 0 ]; then
        text="none pending"
    elif [ -n "$UPDATES_SECURITY" ]; then
        text="$UPDATES_TOTAL pending, $UPDATES_SECURITY of them security"
    else
        text="$UPDATES_TOTAL pending, security count unknown"
    fi
    summary_line "${SUMMARY_LEVEL:-ok}" Updates "$text (warning on any security update)"
}

render_summary() {
    local host distro="" up text i label colour
    local critical=0 warnings=0 notices=0
    local -a counts=()
    SUMMARY_CLAIMED=()

    printf '%s%s[---] SUMMARY%s\n' "$BOLD" "$PURPLE" "$NC"
    section_rule

    host=$(hostname 2>/dev/null)
    if [ -r /etc/os-release ]; then
        distro=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
    fi
    text="${distro:+$distro, }$(uname -s) $(uname -r) ($(uname -m)), run as $ME"
    if command_exists uptime && up=$(uptime -p 2>/dev/null) && [ -n "$up" ]; then
        text+=", $up"
    fi
    printf '  %s%s:%s %s\n\n' "$CYAN" "${host:-this host}" "$NC" "$text"

    summary_bandwidth
    summary_memory
    summary_swap
    summary_load
    summary_disk_space
    summary_inodes
    summary_disk_growth
    summary_reclaimable
    summary_deleted
    summary_munin
    summary_services
    summary_failed_units
    summary_reboot
    summary_updates

    # An issue that no line has shown still appears, so that nothing can
    # vanish from the summary when a new check is added.
    for i in ${ISSUES[@]+"${!ISSUES[@]}"}; do
        [ -n "${SUMMARY_CLAIMED[$i]:-}" ] && continue
        summary_line "${ISSUES[$i]%%|*}" Other "${ISSUES[$i]#*|}"
    done

    for i in ${ISSUES[@]+"${!ISSUES[@]}"}; do
        case "${ISSUES[$i]%%|*}" in
            critical) critical=$((critical + 1)) ;;
            warning)  warnings=$((warnings + 1)) ;;
            *)        notices=$((notices + 1)) ;;
        esac
    done
    [ "$critical" -gt 0 ] && counts+=("$critical critical")
    [ "$warnings" -gt 0 ] && counts+=("$(plural "$warnings" warning warnings)")
    [ "$notices" -gt 0 ]  && counts+=("$(plural "$notices" notice notices)")

    case "$OVERALL_STATUS" in
        "$EXIT_CRITICAL") label="CRITICAL"; colour="$RED"   ;;
        "$EXIT_WARNING")  label="WARNING";  colour="$RED"   ;;
        *)                label="OK";       colour="$GREEN" ;;
    esac
    if [ ${#counts[@]} -gt 0 ]; then
        text=$(join_words "${counts[@]}")
    else
        text="nothing needs attention"
    fi
    # The colour first: its code begins with a reset, which would cancel the bold.
    printf '\n%s%sOverall status: %s%s (exit %s), %s\n\n' \
        "$colour" "$BOLD" "$label" "$NC" "$OVERALL_STATUS" "$text"
}

render_text() {
    render_header
    render_network
    render_memory
    render_load
    render_disk
    render_disk_analysis
    render_status
    render_top_processes
    render_summary
}

# ---------------------------------------------------------------------------
# JSON rendering
# ---------------------------------------------------------------------------
# json_string_or_null <value>: a quoted, escaped JSON string, or null for "" and "-".
json_string_or_null() {
    if [ -z "${1:-}" ] || [ "$1" = "-" ]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

# json_list <name> <indent> <array entries...>: prints `"name": [ ... ]`, each
# entry already a JSON object, with commas in between.
json_list() {
    local name="$1" indent="$2" i=0 n entry
    shift 2
    n=$#
    if [ "$n" -eq 0 ]; then
        printf '%s"%s": []' "$indent" "$name"
        return
    fi
    printf '%s"%s": [\n' "$indent" "$name"
    for entry in "$@"; do
        i=$((i + 1))
        printf '%s  %s' "$indent" "$entry"
        [ "$i" -lt "$n" ] && printf ','
        printf '\n'
    done
    printf '%s]' "$indent"
}

render_json_disk_analysis() {
    local -a items=()
    local row line mount state slope pace days n span level kb change path mtime
    local category safety action command note pid process scanned used

    printf '  "disk_analysis": {\n'
    printf '    "state_dir": %s,\n' "$(json_string_or_null "$STATE_DIR")"
    printf '    "state_writable": %s,\n' "$([ "$STATE_OK" -eq 1 ] && echo true || echo false)"

    for row in ${TREND_ROWS[@]+"${TREND_ROWS[@]}"}; do
        IFS='|' read -r mount state slope pace days n span level <<<"$row"
        items+=("$(printf '{"mount": "%s", "state": "%s", "rate_kb_per_day": %s, "pace_24h_kb_per_day": %s, "days_to_full": %s, "samples": %s, "span_hours": %s, "level": "%s"}' \
            "$(json_escape "$mount")" "$state" "$(json_num "$slope")" "$(json_num "$pace")" \
            "$(json_num "$days")" "$(json_num "$n")" "$(json_num "$span")" "$level")")
    done
    json_list trends '    ' ${items[@]+"${items[@]}"}
    printf ',\n'

    printf '    "scan": {"status": "%s", "started": %s, "finished": %s, "roots": %s, "unreadable_dirs": %s, "skipped_paths": %s, "note": %s},\n' \
        "$SCAN_STATUS" "$(json_num "$SCAN_STARTED")" "$(json_num "$SCAN_FINISHED")" \
        "$(json_string_or_null "$SCAN_ROOTS")" "$(json_num "$SCAN_UNREADABLE")" \
        "$(json_num "$SCAN_SKIPPED")" "$(json_string_or_null "$SCAN_NOTE")"

    items=()
    for row in ${COVERAGE_ROWS[@]+"${COVERAGE_ROWS[@]}"}; do
        IFS='|' read -r mount scanned used <<<"$row"
        items+=("$(printf '{"mount": "%s", "scanned_kb": %s, "used_kb": %s}' \
            "$(json_escape "$mount")" "$(json_num "$scanned")" "$(json_num "$used")")")
    done
    json_list coverage '    ' ${items[@]+"${items[@]}"}
    printf ',\n'

    items=()
    for line in ${DIR_TOP_ROWS[@]+"${DIR_TOP_ROWS[@]}"}; do
        IFS=$'\t' read -r kb change path <<<"$line"
        items+=("$(printf '{"path": "%s", "kb": %s, "change_kb": %s}' \
            "$(json_escape "$path")" "$(json_num "$kb")" "$(json_num "$change")")")
    done
    json_list largest_dirs '    ' ${items[@]+"${items[@]}"}
    printf ',\n'

    items=()
    for line in ${GROW_ROWS[@]+"${GROW_ROWS[@]}"}; do
        IFS=$'\t' read -r kb path <<<"$line"
        items+=("$(printf '{"path": "%s", "change_kb": %s}' "$(json_escape "$path")" "$(json_num "$kb")")")
    done
    json_list growing_dirs '    ' ${items[@]+"${items[@]}"}
    printf ',\n'
    printf '    "growth_since": %s,\n' "$(json_num "$GROWTH_SINCE")"

    items=()
    for line in ${BIGFILE_ROWS[@]+"${BIGFILE_ROWS[@]}"}; do
        IFS=$'\t' read -r kb mtime path <<<"$line"
        items+=("$(printf '{"path": "%s", "kb": %s, "mtime": %s}' \
            "$(json_escape "$path")" "$(json_num "$kb")" "$(json_num "$mtime")")")
    done
    json_list large_files '    ' ${items[@]+"${items[@]}"}
    printf ',\n'

    items=()
    for line in ${SAVING_ROWS[@]+"${SAVING_ROWS[@]}"}; do
        IFS=$'\t' read -r kb category safety action path command note <<<"$line"
        items+=("$(printf '{"id": %s, "category": "%s", "safety": "%s", "kb": %s, "action": %s, "path": %s, "command": %s, "note": %s}' \
            "$(json_string_or_null "$(saving_id "$action" "$path")")" \
            "$(json_escape "$category")" "$safety" "$(json_num "$kb")" \
            "$(json_string_or_null "$action")" "$(json_string_or_null "$path")" \
            "$(json_string_or_null "$command")" "$(json_string_or_null "$note")")")
    done
    json_list savings '    ' ${items[@]+"${items[@]}"}
    printf ',\n'
    printf '    "savings_safe_kb": %s,\n' "$(json_num "$SAVINGS_SAFE_KB")"
    printf '    "savings_review_kb": %s,\n' "$(json_num "$SAVINGS_REVIEW_KB")"

    items=()
    for line in ${DELETED_ROWS[@]+"${DELETED_ROWS[@]}"}; do
        IFS=$'\t' read -r kb pid process path <<<"$line"
        items+=("$(printf '{"pid": %s, "process": "%s", "kb": %s, "path": "%s"}' \
            "$(json_num "$pid")" "$(json_escape "$process")" "$(json_num "$kb")" "$(json_escape "$path")")")
    done
    json_list deleted_open '    ' ${items[@]+"${items[@]}"}
    printf ',\n'
    printf '    "deleted_open_kb": %s\n' "$(json_num "$DELETED_KB")"
    printf '  },\n'
}

render_json() {
    local status_label
    case "$OVERALL_STATUS" in
        "$EXIT_CRITICAL") status_label="critical" ;;
        "$EXIT_WARNING")  status_label="warning"  ;;
        *)                status_label="ok"       ;;
    esac

    printf '{\n'
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "generated": "%s",\n' "$(date -Is 2>/dev/null || date)"
    printf '  "hostname": "%s",\n' "$(json_escape "$(hostname)")"
    printf '  "status": "%s",\n' "$status_label"
    printf '  "exit_code": %s,\n' "$OVERALL_STATUS"

    printf '  "network": {\n'
    printf '    "source": "%s",\n' "$(json_escape "$NET_SOURCE")"
    printf '    "interface": "%s",\n' "$(json_escape "$NET_IFACE")"
    printf '    "count_mode": "%s",\n' "$(json_escape "$BANDWIDTH_COUNT_MODE")"
    printf '    "limit_tb": %s,\n' "$(json_num "$BANDWIDTH_LIMIT_TB")"
    printf '    "limit_bytes": %s,\n' "$(json_num "$NET_LIMIT_BYTES")"
    printf '    "month_rx_bytes": %s,\n' "$(json_num "$NET_RX")"
    printf '    "month_tx_bytes": %s,\n' "$(json_num "$NET_TX")"
    printf '    "metered_bytes": %s,\n' "$(json_num "$NET_COUNTED")"
    printf '    "used_pct": %s,\n' "$(json_num "$NET_PCT")"
    printf '    "projected_bytes": %s,\n' "$(json_num "$NET_PROJECTED")"
    printf '    "projected_pct": %s,\n' "$(json_num "$NET_PROJECTED_PCT")"
    printf '    "since_boot_rx_bytes": %s,\n' "$(json_num "$NET_BOOT_RX")"
    printf '    "since_boot_tx_bytes": %s\n' "$(json_num "$NET_BOOT_TX")"
    printf '  },\n'

    printf '  "memory": {\n'
    printf '    "total_kb": %s,\n' "$(json_num "$MEM_TOTAL_KB")"
    printf '    "used_kb": %s,\n' "$(json_num "$MEM_USED_KB")"
    printf '    "available_kb": %s,\n' "$(json_num "$MEM_AVAIL_KB")"
    printf '    "used_pct": %s,\n' "$(json_num "$MEM_PCT")"
    printf '    "swap_total_kb": %s,\n' "$(json_num "$SWAP_TOTAL_KB")"
    printf '    "swap_used_kb": %s,\n' "$(json_num "$SWAP_USED_KB")"
    printf '    "swap_used_pct": %s\n' "$(json_num "$SWAP_PCT")"
    printf '  },\n'

    printf '  "load": {\n'
    printf '    "avg_1m": %s,\n' "$(json_num "$LOAD_1")"
    printf '    "avg_5m": %s,\n' "$(json_num "$LOAD_5")"
    printf '    "avg_15m": %s,\n' "$(json_num "$LOAD_15")"
    printf '    "cpu_cores": %s,\n' "$(json_num "$CPU_CORES")"
    printf '    "load_pct": %s,\n' "$(json_num "$LOAD_PCT")"
    printf '    "cpu_usage_pct": %s\n' "$(json_num "$CPU_USAGE")"
    printf '  },\n'

    printf '  "filesystems": [\n'
    local i row mount fs type size used avail pct level
    for i in ${DISK_ROWS[@]+"${!DISK_ROWS[@]}"}; do
        IFS='|' read -r mount fs type size used avail pct level <<<"${DISK_ROWS[$i]}"
        printf '    {"mount": "%s", "device": "%s", "type": "%s", "size_kb": %s, ' \
            "$(json_escape "$mount")" "$(json_escape "$fs")" "$(json_escape "$type")" \
            "$(json_num "$size")"
        printf '"used_kb": %s, "available_kb": %s, "used_pct": %s, "level": "%s"}' \
            "$(json_num "$used")" "$(json_num "$avail")" "$(json_num "$pct")" "$level"
        [ "$i" -lt $((${#DISK_ROWS[@]} - 1)) ] && printf ','
        printf '\n'
    done
    printf '  ],\n'

    render_json_disk_analysis

    printf '  "system": {\n'
    printf '    "munin_critical": %s,\n' "$(json_num "$MUNIN_CRITICAL")"
    printf '    "munin_warning": %s,\n' "$(json_num "$MUNIN_WARNING")"
    printf '    "services_ok": %s,\n' "$(json_num "$SERVICES_OK")"
    printf '    "services_total": %s,\n' "$(json_num "$SERVICES_TOTAL")"
    printf '    "failed_units": %s,\n' "$(json_num "$FAILED_UNITS")"
    local ignored_units="" unit
    for unit in ${IGNORED_UNIT_NAMES[@]+"${IGNORED_UNIT_NAMES[@]}"}; do
        ignored_units+="${ignored_units:+, }\"$(json_escape "$unit")\""
    done
    printf '    "failed_units_ignored": [%s],\n' "$ignored_units"
    printf '    "reboot_required": "%s",\n' "$REBOOT_REQUIRED"
    printf '    "updates_pending": %s,\n' "$(json_num "$UPDATES_TOTAL")"
    printf '    "updates_security": %s\n' "$(json_num "$UPDATES_SECURITY")"
    printf '  },\n'

    printf '  "issues": [\n'
    local issue level message
    for i in ${ISSUES[@]+"${!ISSUES[@]}"}; do
        issue="${ISSUES[$i]}"
        level="${issue%%|*}"
        message="${issue#*|}"
        printf '    {"level": "%s", "key": "%s", "message": "%s"}' "$level" \
            "$(json_escape "${ISSUE_KEYS[$i]}")" "$(json_escape "$message")"
        [ "$i" -lt $((${#ISSUES[@]} - 1)) ] && printf ','
        printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
$PROGNAME v$VERSION - VPS resource usage report with monthly bandwidth tracking

Usage: $PROGNAME [options]

Options:
  -j, --json            Machine-readable JSON instead of the text report
      --color=WHEN      Colourise output: auto (default), always, never
      --no-color        Same as --color=never
      --scan            Rescan the folders now (otherwise the cached scan is used)
      --no-scan         Never start a folder scan; show the cached one, if any
      --clean           Offer the safe clean-ups one at a time, asking before each
      --free WHAT       Free safe items without asking: list, all, or names
                        separated by commas (e.g. pnpm-store,npm-cache)
  -y, --yes             With --clean: free every safe item without asking
                        (same as --free all; for an agent such as Hermes)
      --notify          Send an alert when something needs attention (for cron)
      --notify-test     Send a test alert through the configured channel and exit
  -q, --quiet           Print nothing; with --notify, for cron
  -V, --version         Print version and exit
  -h, --help            Print this help and exit

Exit codes:
  0  OK          nothing exceeded a threshold
  1  WARNING     at least one warning threshold exceeded
  2  CRITICAL    at least one critical threshold exceeded
  3  usage error

Configuration is read from, in increasing precedence:
  built-in defaults
  \$VPSUSAGECHECK_CONF, \${XDG_CONFIG_HOME:-\$HOME/.config}/vpsusagecheck/config,
    \$HOME/.vpsusagecheckrc, /etc/vpsusagecheck.conf  (first readable one)
  environment variables
  command-line flags

Common settings (see README.md for the full list):
  BANDWIDTH_LIMIT_TB=$BANDWIDTH_LIMIT_TB          monthly cap in TiB
  BANDWIDTH_COUNT_MODE=$BANDWIDTH_COUNT_MODE        what the provider meters: out|in|sum|max
  NET_INTERFACE=            interface to measure (default: the default route)
  DISK_FILL_WARN_DAYS=$DISK_FILL_WARN_DAYS        warn when a disk will be full within this many days
  NOTIFY_HERMES_TO=         Hermes target for alerts, e.g. telegram
  NOTIFY_COMMAND=           any command; gets \$NOTIFY_SUBJECT and \$NOTIFY_BODY_FILE

Cron, hourly, alerting through Hermes:
  0 * * * * NOTIFY_HERMES_TO=telegram $PROGNAME --notify --quiet
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -j|--json)     OUTPUT_FORMAT="json" ;;
            --color=*)     COLOR_WHEN="${1#*=}" ;;
            --color)       shift; COLOR_WHEN="${1:-auto}" ;;
            --no-color)    COLOR_WHEN="never" ;;
            --scan)        SCAN_MODE="force" ;;
            --no-scan)     SCAN_MODE="skip" ;;
            --clean)       RUN_MODE="clean" ;;
            --free=*)      RUN_MODE="free"; FREE_REQUEST="${1#*=}" ;;
            --free)
                RUN_MODE="free"
                if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then shift; FREE_REQUEST="$1"; fi
                ;;
            --notify)      NOTIFY_MODE=1 ;;
            --notify-test) RUN_MODE="notify-test" ;;
            -q|--quiet)    QUIET=1 ;;
            -y|--yes)      ASSUME_YES=1 ;;
            -V|--version)  printf '%s %s\n' "$PROGNAME" "$VERSION"; exit "$EXIT_OK" ;;
            -h|--help)     usage; exit "$EXIT_OK" ;;
            --)            shift; break ;;
            *)
                printf '%s: unknown option: %s\n' "$PROGNAME" "$1" >&2
                printf "Try '%s --help'.\n" "$PROGNAME" >&2
                exit "$EXIT_USAGE"
                ;;
        esac
        shift
    done

    case "$COLOR_WHEN" in
        auto|always|never) ;;
        *)
            printf '%s: invalid --color value: %s (use auto, always or never)\n' \
                "$PROGNAME" "$COLOR_WHEN" >&2
            exit "$EXIT_USAGE"
            ;;
    esac

    case "$BANDWIDTH_COUNT_MODE" in
        out|in|sum|max) ;;
        *)
            printf '%s: invalid BANDWIDTH_COUNT_MODE: %s (use out, in, sum or max)\n' \
                "$PROGNAME" "$BANDWIDTH_COUNT_MODE" >&2
            exit "$EXIT_USAGE"
            ;;
    esac

    local key
    for key in DISK_TREND_DAYS DISK_FILL_NOTICE_DAYS DISK_FILL_WARN_DAYS DISK_FILL_CRITICAL_DAYS \
               DISK_SCAN_MAX_AGE_HOURS DISK_SCAN_TIMEOUT DISK_TOP_MIN_MB DISK_BIGFILE_MB \
               DISK_RECLAIM_MIN_MB DISK_RECLAIM_NOTICE_GB NOTIFY_REPEAT_HOURS; do
        if ! is_number "${!key}" || compare_gt 0 "${!key}"; then
            usage_error "invalid $key: ${!key} (expected a number, 0 or more)"
        fi
    done
    for key in DISK_SCAN_DEPTH DISK_TOP_COUNT DISK_JOURNAL_KEEP_MB; do
        case "${!key}" in
            ''|*[!0-9]*) usage_error "invalid $key: ${!key} (expected a whole number)" ;;
        esac
    done
    case "$NOTIFY_MIN_LEVEL" in
        notice|warning|critical) ;;
        *) usage_error "invalid NOTIFY_MIN_LEVEL: $NOTIFY_MIN_LEVEL (use notice, warning or critical)" ;;
    esac
    case "$DISK_SCAN" in 0|1) ;; *) usage_error "invalid DISK_SCAN: $DISK_SCAN (use 0 or 1)" ;; esac
    case "$NOTIFY_RECOVERY" in 0|1) ;; *) usage_error "invalid NOTIFY_RECOVERY: $NOTIFY_RECOVERY (use 0 or 1)" ;; esac
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit "$EXIT_USAGE"
}

main() {
    parse_args "$@"
    setup_colors
    umask 077
    state_init

    if [ "$RUN_MODE" = "clean" ] && [ "$ASSUME_YES" -eq 1 ]; then
        RUN_MODE="free"
        FREE_REQUEST="all"
    fi
    if [ "$RUN_MODE" = "clean" ]; then
        run_clean
        exit "$EXIT_OK"
    fi
    if [ "$RUN_MODE" = "free" ]; then
        if run_free; then exit "$EXIT_OK"; else exit "$?"; fi
    fi

    collect_network
    collect_memory
    collect_load
    collect_disk
    collect_disk_forecast
    collect_disk_analysis
    collect_deleted_open
    collect_munin_problems || true
    collect_services
    collect_failed_units
    collect_reboot_required
    collect_updates
    collect_top_processes

    if [ "$RUN_MODE" = "notify-test" ]; then
        notify_test
    fi

    if [ "$QUIET" -eq 0 ]; then
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            render_json
        else
            render_text
        fi
    fi

    if [ "$NOTIFY_MODE" -eq 1 ]; then
        notify_maybe
    fi

    exit "$OVERALL_STATUS"
}

# Run unless sourced (tests source the file to call single functions). Under
# `bash -s` BASH_SOURCE is empty, hence the fallback to $0.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
