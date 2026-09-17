#!/usr/bin/env bash
#
# vpsusagecheck - VPS resource usage report with monthly outbound bandwidth tracking.
#
# Reports network, memory, CPU, disk and system health, and warns before you run
# into your provider's monthly outbound bandwidth cap.
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

readonly VERSION="2.0.0"
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
    CHECK_FAILED_UNITS CHECK_REBOOT_REQUIRED CHECK_UPDATES
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
CHECK_REBOOT_REQUIRED="${CHECK_REBOOT_REQUIRED:-1}"
CHECK_UPDATES="${CHECK_UPDATES:-1}"

# ---------------------------------------------------------------------------
# Output mode
# ---------------------------------------------------------------------------
OUTPUT_FORMAT="text"
COLOR_WHEN="auto"

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

# record_issue <level: notice|warning|critical> <message>
record_issue() {
    local level="$1" message="$2"
    ISSUES+=("$level|$message")
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
    read -r _ s1[0] s1[1] s1[2] s1[3] s1[4] s1[5] s1[6] s1[7] s1[8] s1[9] < /proc/stat
    sleep 1
    read -r _ s2[0] s2[1] s2[2] s2[3] s2[4] s2[5] s2[6] s2[7] s2[8] s2[9] < /proc/stat

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
        # Fields 14 and 15 are the current month's rx and tx.
        out=$(vnstat --oneline b ${ifarg[@]+"${ifarg[@]}"} 2>/dev/null) || return 1
        rx=$(printf '%s' "$out" | awk -F';' '{print $14}')
        tx=$(printf '%s' "$out" | awk -F';' '{print $15}')
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
                "Outbound bandwidth at ${NET_PCT}% of the ${BANDWIDTH_LIMIT_TB}TB monthly cap"
        elif compare_gt "$NET_PCT" "$BANDWIDTH_NOTICE_PCT"; then
            record_issue notice \
                "Over ${BANDWIDTH_NOTICE_PCT}% of the monthly bandwidth cap used"
        elif compare_gt "${NET_PROJECTED_PCT:-0}" "100"; then
            record_issue warning \
                "Projected to exceed the monthly cap (${NET_PROJECTED_PCT}% by month end)"
        fi
    else
        record_issue notice \
            "No month-to-date bandwidth source (install vnstat for cap tracking)"
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
        record_issue warning "Memory usage at ${MEM_PCT}%"
    elif compare_gt "$MEM_PCT" "$MEMORY_NOTICE_PCT"; then
        record_issue notice "Memory usage above ${MEMORY_NOTICE_PCT}% (${MEM_PCT}%)"
    fi

    if [ "${swaptotal:-0}" -gt 0 ] 2>/dev/null; then
        SWAP_TOTAL_KB="$swaptotal"
        SWAP_USED_KB=$((swaptotal - swapfree))
        SWAP_PCT=$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL_KB" \
            'BEGIN {printf "%.1f", (u / t) * 100}')
        if compare_gt "$SWAP_PCT" "$SWAP_WARN_PCT"; then
            record_issue warning "Swap usage at ${SWAP_PCT}%"
        elif compare_gt "$SWAP_PCT" "$SWAP_NOTICE_PCT"; then
            record_issue notice "Swap usage above ${SWAP_NOTICE_PCT}% (${SWAP_PCT}%)"
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
        record_issue warning "Load average ${LOAD_1} exceeds ${warn_threshold} (${CPU_CORES} cores)"
    elif compare_gt "$LOAD_PCT" "$LOAD_NOTICE_PCT"; then
        record_issue notice "Load at ${LOAD_PCT}% of capacity"
    fi
}

# ---------------------------------------------------------------------------
# Disk and inodes
# ---------------------------------------------------------------------------
# Rows are "mount|filesystem|type|size_kb|used_kb|avail_kb|use_pct|level".
DISK_ROWS=()
INODE_ROWS=()

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
                record_issue critical "$mount is ${pct}% full"
            elif compare_gt "$pct" "$DISK_WARN_PCT"; then
                level="warning"
                record_issue warning "$mount is ${pct}% full"
            elif compare_gt "$pct" "$DISK_NOTICE_PCT"; then
                level="notice"
                record_issue notice "$mount is ${pct}% full"
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
            record_issue warning "$mount inode usage at ${pct}%"
        elif compare_gt "$pct" "$INODE_NOTICE_PCT"; then
            level="notice"
            record_issue notice "$mount inode usage at ${pct}%"
        fi
        [ "$level" = "ok" ] && continue
        INODE_ROWS+=("$mount|$inodes|$iused|$ifree|$pct|$level")
    done < <(df -PTi 2>/dev/null | tail -n +2)
}

# ---------------------------------------------------------------------------
# System health
# ---------------------------------------------------------------------------
MUNIN_CRITICAL="" MUNIN_WARNING="" MUNIN_UNKNOWN=""
SERVICES_OK="" SERVICES_TOTAL="" SERVICES_DOWN=()
FAILED_UNITS="" FAILED_UNIT_NAMES=()
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
        record_issue critical "Munin reports ${MUNIN_CRITICAL} critical plugin state(s)"
    elif [ "$MUNIN_WARNING" -gt 0 ]; then
        record_issue warning "Munin reports ${MUNIN_WARNING} warning plugin state(s)"
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

        SERVICES_TOTAL=$((SERVICES_TOTAL + 1))
        if service_is_active "$name"; then
            SERVICES_OK=$((SERVICES_OK + 1))
        else
            SERVICES_DOWN+=("$name")
            record_issue warning "Service $name is not running"
        fi
    done
}

collect_failed_units() {
    if [ "$CHECK_FAILED_UNITS" != "1" ] || ! command_exists systemctl; then return 0; fi
    local names
    names=$(systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -v '^$') || true
    if [ -n "$names" ]; then
        mapfile -t FAILED_UNIT_NAMES <<<"$names"
        FAILED_UNITS=${#FAILED_UNIT_NAMES[@]}
        record_issue warning "${FAILED_UNITS} failed systemd unit(s): ${FAILED_UNIT_NAMES[*]}"
    else
        FAILED_UNITS=0
    fi
}

collect_reboot_required() {
    [ "$CHECK_REBOOT_REQUIRED" = "1" ] || return 0
    if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
        REBOOT_REQUIRED="yes"
        record_issue notice "A reboot is required to finish applying updates"
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
        record_issue warning "${UPDATES_SECURITY} security update(s) pending"
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
            printf '  %sFailed units:%s  %s%s%s\n' \
                "$YELLOW" "$NC" "$RED" "${FAILED_UNIT_NAMES[*]}" "$NC"
        else
            printf '  %sFailed units:%s  none\n' "$YELLOW" "$NC"
        fi
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

render_summary() {
    printf '%s%s[---] SUMMARY%s\n' "$BOLD" "$PURPLE" "$NC"
    section_rule
    printf '  %sOS:%s     %s %s (%s)\n' "$CYAN" "$NC" "$(uname -s)" "$(uname -r)" "$(uname -m)"
    if [ -r /etc/os-release ]; then
        printf '  %sDistro:%s %s\n' "$CYAN" "$NC" \
            "$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)"
    fi
    printf '  %sUser:%s   %s\n' "$CYAN" "$NC" "$(id -un)"
    printf '\n'

    local label colour
    case "$OVERALL_STATUS" in
        "$EXIT_CRITICAL") label="CRITICAL"; colour="$RED"    ;;
        "$EXIT_WARNING")  label="WARNING";  colour="$YELLOW" ;;
        *)                label="OK";       colour="$GREEN"  ;;
    esac
    printf '%s%sOverall status: %s%s (exit %s)\n' \
        "$BOLD" "$colour" "$label" "$NC" "$OVERALL_STATUS"

    local issue level message
    for issue in ${ISSUES[@]+"${ISSUES[@]}"}; do
        level="${issue%%|*}"
        message="${issue#*|}"
        case "$level" in
            critical) colour="$RED"    ;;
            warning)  colour="$RED"    ;;
            *)        colour="$YELLOW" ;;
        esac
        printf '  %s[%s]%s %s\n' "$colour" "$level" "$NC" "$message"
    done
    [ ${#ISSUES[@]} -eq 0 ] && printf '  %sNothing needs attention.%s\n' "$GREEN" "$NC"
    printf '\n'
}

render_text() {
    render_header
    render_network
    render_memory
    render_load
    render_disk
    render_status
    render_top_processes
    render_summary
}

# ---------------------------------------------------------------------------
# JSON rendering
# ---------------------------------------------------------------------------
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

    printf '  "system": {\n'
    printf '    "munin_critical": %s,\n' "$(json_num "$MUNIN_CRITICAL")"
    printf '    "munin_warning": %s,\n' "$(json_num "$MUNIN_WARNING")"
    printf '    "services_ok": %s,\n' "$(json_num "$SERVICES_OK")"
    printf '    "services_total": %s,\n' "$(json_num "$SERVICES_TOTAL")"
    printf '    "failed_units": %s,\n' "$(json_num "$FAILED_UNITS")"
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
        printf '    {"level": "%s", "message": "%s"}' "$level" "$(json_escape "$message")"
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
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -j|--json)     OUTPUT_FORMAT="json" ;;
            --color=*)     COLOR_WHEN="${1#*=}" ;;
            --color)       shift; COLOR_WHEN="${1:-auto}" ;;
            --no-color)    COLOR_WHEN="never" ;;
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
}

main() {
    parse_args "$@"
    setup_colors

    collect_network
    collect_memory
    collect_load
    collect_disk
    collect_munin_problems || true
    collect_services
    collect_failed_units
    collect_reboot_required
    collect_updates
    collect_top_processes

    if [ "$OUTPUT_FORMAT" = "json" ]; then
        render_json
    else
        render_text
    fi

    exit "$OVERALL_STATUS"
}

main "$@"
