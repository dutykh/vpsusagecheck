#!/bin/bash

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Defaults (override by exporting env vars before running the script)
BANDWIDTH_LIMIT_TB="${BANDWIDTH_LIMIT_TB:-32}"
BANDWIDTH_NOTICE_PCT="${BANDWIDTH_NOTICE_PCT:-50}"
BANDWIDTH_WARN_PCT="${BANDWIDTH_WARN_PCT:-80}"
MEMORY_NOTICE_PCT="${MEMORY_NOTICE_PCT:-75}"
MEMORY_WARN_PCT="${MEMORY_WARN_PCT:-90}"
LOAD_NOTICE_PCT="${LOAD_NOTICE_PCT:-75}"
LOAD_WARN_MULTIPLIER="${LOAD_WARN_MULTIPLIER:-1}"
DISK_NOTICE_PCT="${DISK_NOTICE_PCT:-80}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
DISK_CRITICAL_PCT="${DISK_CRITICAL_PCT:-95}"
INODE_NOTICE_PCT="${INODE_NOTICE_PCT:-80}"
INODE_WARN_PCT="${INODE_WARN_PCT:-90}"

# Function to convert bytes to human readable format
bytes_to_human() {
    local bytes=$1
    if [ $bytes -ge 1099511627776 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}") TB"
    elif [ $bytes -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}") GB"
    elif [ $bytes -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}") MB"
    elif [ $bytes -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}") KB"
    else
        echo "$bytes B"
    fi
}

# Function to convert KB to human readable format
kb_to_human() {
    local kb=$1
    local bytes=$((kb * 1024))
    bytes_to_human $bytes
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to compare two numeric values (supports decimals)
compare_gt() {
    awk -v left="$1" -v right="$2" 'BEGIN {exit !(left > right)}'
}

# Function to detect mount types that are not useful for capacity alerts
is_ignored_fs_type() {
    case "$1" in
        tmpfs|devtmpfs|proc|sysfs|overlay|squashfs|*squash*|efivarfs|cgroup|cgroup2|debugfs|tracefs|pstore|securityfs|mqueue|fusectl|configfs|autofs|ramfs|hugetlbfs|binfmt_misc|bpf|nsfs)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check if a service exists
service_exists() {
    local name="$1"
    if command_exists systemctl; then
        systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${name}.service"
        return $?
    fi
    [ -x "/etc/init.d/$name" ]
}

# Function to check if a service is active
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

# Function to estimate current CPU usage from a short interval sample
get_cpu_usage_percent() {
    local user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 guest1 guest_nice1
    local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2
    local total1 total2 idle_total1 idle_total2 total_delta idle_delta

    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 guest1 guest_nice1 < /proc/stat
    sleep 1
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 < /proc/stat

    total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1 + guest1 + guest_nice1))
    total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2 + guest2 + guest_nice2))
    idle_total1=$((idle1 + iowait1))
    idle_total2=$((idle2 + iowait2))
    total_delta=$((total2 - total1))
    idle_delta=$((idle_total2 - idle_total1))

    if [ "$total_delta" -le 0 ]; then
        echo "0.0"
        return
    fi

    awk "BEGIN {printf \"%.1f\", (($total_delta - $idle_delta) / $total_delta) * 100}"
}

# Function to get monthly traffic from Munin RRD
get_monthly_traffic() {
    local rrd_file="$1"
    
    if [ ! -f "$rrd_file" ]; then
        echo "0"
        return
    fi
    
    # Get first day of current month timestamp
    local current_month_start=$(date -d "$(date +%Y-%m-01)" +%s)
    local now=$(date +%s)
    
    # Fetch data from beginning of month to now
    local total_bytes=0
    if command_exists rrdtool; then
        local step=300
        step=$(rrdtool info "$rrd_file" 2>/dev/null | awk -F' = ' '/^step =/ {print $2; exit}')
        step=${step:-300}

        # Get average bytes per second and multiply by time intervals to get total bytes
        local rrd_data=$(rrdtool fetch "$rrd_file" AVERAGE --start $current_month_start --end $now 2>/dev/null | grep -v "nan" | awk 'NF==2 && $2!="nan" {sum+=$2} END {print sum}')
        
        if [ ! -z "$rrd_data" ] && [ "$rrd_data" != "" ]; then
            # Convert from bytes/second average to total bytes based on RRD step size
            total_bytes=$(awk "BEGIN {printf \"%.0f\", $rrd_data * $step}")
        fi
    fi
    
    echo "$total_bytes"
}

echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║             MUNIN SERVER MONITORING                            ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}Generated: $(date)${NC}"
echo -e "${CYAN}Hostname: $(hostname)${NC}"
echo

# Network Traffic Analysis
echo -e "${BOLD}${GREEN}📊 NETWORK TRAFFIC (Outgoing Bandwidth - ${BANDWIDTH_LIMIT_TB}TB Monthly Limit)${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"

# Try to get monthly data from Munin RRD files
monthly_found=false
rrd_down_file="/var/lib/munin/localdomain/localhost.localdomain-if_eth0-down-d.rrd"
rrd_up_file="/var/lib/munin/localdomain/localhost.localdomain-if_eth0-up-d.rrd"

if [ -f "$rrd_up_file" ] && [ -f "$rrd_down_file" ]; then
    monthly_down_bytes=$(get_monthly_traffic "$rrd_down_file")
    monthly_up_bytes=$(get_monthly_traffic "$rrd_up_file")
    
    if [ "$monthly_down_bytes" != "0" ] || [ "$monthly_up_bytes" != "0" ]; then
        monthly_found=true
        down_human=$(bytes_to_human $monthly_down_bytes)
        up_human=$(bytes_to_human $monthly_up_bytes)
        
        # Calculate percentage of monthly limit based only on outgoing traffic
        monthly_limit_bytes=$((BANDWIDTH_LIMIT_TB * 1099511627776))
        percentage=$(awk "BEGIN {printf \"%.4f\", ($monthly_up_bytes/$monthly_limit_bytes)*100}")
        
        echo -e "  ${YELLOW}📥 Monthly Inbound:${NC}  $down_human"
        echo -e "  ${YELLOW}📤 Monthly Outbound:${NC} $up_human"
        echo -e "  ${CYAN}📈 Monthly Usage:${NC}     ${percentage}% of ${BANDWIDTH_LIMIT_TB}TB outgoing limit"
        
        # Warning if approaching limits
        if compare_gt "$percentage" "$BANDWIDTH_WARN_PCT"; then
            echo -e "  ${RED}⚠️  WARNING: Approaching outgoing bandwidth limit!${NC}"
        elif compare_gt "$percentage" "$BANDWIDTH_NOTICE_PCT"; then
            echo -e "  ${YELLOW}⚠️  NOTICE: Over ${BANDWIDTH_NOTICE_PCT}% of monthly outgoing bandwidth used${NC}"
        fi
        
        # Show current session info
        if [ -f /proc/net/dev ]; then
            interface=$(awk 'NR>2 && $1!~/lo:/ && $2>0 {gsub(/:/, "", $1); print $1; exit}' /proc/net/dev)
            if [ ! -z "$interface" ]; then
                rx_bytes=$(awk -v iface="$interface:" '$1==iface {print $2}' /proc/net/dev)
                tx_bytes=$(awk -v iface="$interface:" '$1==iface {print $10}' /proc/net/dev)
                
                if [ ! -z "$rx_bytes" ] && [ ! -z "$tx_bytes" ]; then
                    rx_human=$(bytes_to_human $rx_bytes)
                    tx_human=$(bytes_to_human $tx_bytes)
                    
                    echo -e "  ${BLUE}📊 Since Last Reboot:${NC}"
                    echo -e "     📥 Received: $rx_human"
                    echo -e "     📤 Sent: $tx_human"
                    echo -e "     🕐 Uptime: $(uptime -p)"
                fi
            fi
        fi
    fi
fi

if [ "$monthly_found" = false ]; then
    echo -e "  ${RED}❌ Monthly traffic data not available from Munin RRD${NC}"
    echo -e "  ${YELLOW}📊 Falling back to current session data:${NC}"
    
    # Fallback to /proc/net/dev (current session only)
    if [ -f /proc/net/dev ]; then
        interface=$(awk 'NR>2 && $1!~/lo:/ && $2>0 {gsub(/:/, "", $1); print $1; exit}' /proc/net/dev)
        if [ ! -z "$interface" ]; then
            rx_bytes=$(awk -v iface="$interface:" '$1==iface {print $2}' /proc/net/dev)
            tx_bytes=$(awk -v iface="$interface:" '$1==iface {print $10}' /proc/net/dev)
            
            if [ ! -z "$rx_bytes" ] && [ ! -z "$tx_bytes" ]; then
                rx_human=$(bytes_to_human $rx_bytes)
                tx_human=$(bytes_to_human $tx_bytes)
                
                echo -e "  ${YELLOW}📥 Received (since reboot):${NC} $rx_human"
                echo -e "  ${YELLOW}📤 Sent (since reboot):${NC} $tx_human"
                echo -e "  ${CYAN}📝 Note: These are session totals since last reboot${NC}"
                echo -e "  ${CYAN}🕐 Uptime: $(uptime -p)${NC}"
            fi
        fi
    else
        echo -e "  ${RED}❌ Network monitoring not available${NC}"
    fi
fi
echo

# Memory Usage
echo -e "${BOLD}${GREEN}💾 MEMORY USAGE${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"

if [ -f /proc/meminfo ]; then
    mem_data=$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} /^MemFree:/ {free=$2} /^Buffers:/ {buffers=$2} /^Cached:/ {cached=$2} END {print total, avail, free, buffers, cached}' /proc/meminfo)
    read -r mem_total mem_available mem_free mem_buffers mem_cached <<< "$mem_data"
    
    # Use MemAvailable if available, otherwise calculate
    if [ ! -z "$mem_available" ]; then
        mem_used=$((mem_total - mem_available))
    else
        mem_used=$((mem_total - mem_free - mem_buffers - mem_cached))
        mem_available=$((mem_free + mem_buffers + mem_cached))
    fi
    
    mem_total_human=$(kb_to_human $mem_total)
    mem_used_human=$(kb_to_human $mem_used)
    mem_available_human=$(kb_to_human $mem_available)
    
    usage_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")
    
    echo -e "  ${YELLOW}📊 Total:${NC}     $mem_total_human"
    echo -e "  ${YELLOW}🔴 Used:${NC}      $mem_used_human (${usage_percent}%)"
    echo -e "  ${YELLOW}🟢 Available:${NC} $mem_available_human"
    
    # Memory usage warning
    if compare_gt "$usage_percent" "$MEMORY_WARN_PCT"; then
        echo -e "  ${RED}⚠️  WARNING: High memory usage!${NC}"
    elif compare_gt "$usage_percent" "$MEMORY_NOTICE_PCT"; then
        echo -e "  ${YELLOW}⚠️  NOTICE: Memory usage above ${MEMORY_NOTICE_PCT}%${NC}"
    fi
    
    # Show swap if available
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_free=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    if [ ! -z "$swap_total" ] && [ "$swap_total" -gt 0 ]; then
        swap_used=$((swap_total - swap_free))
        swap_total_human=$(kb_to_human $swap_total)
        swap_used_human=$(kb_to_human $swap_used)
        swap_percent=$(awk "BEGIN {printf \"%.1f\", ($swap_used/$swap_total)*100}")
        echo -e "  ${PURPLE}🔄 Swap Used:${NC} $swap_used_human of $swap_total_human (${swap_percent}%)"
    fi
else
    echo -e "  ${RED}❌ Memory information not available${NC}"
fi
echo

# CPU Load
echo -e "${BOLD}${GREEN}🔧 SYSTEM LOAD${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"

if [ -f /proc/loadavg ]; then
    load_1min=$(awk '{print $1}' /proc/loadavg)
    load_5min=$(awk '{print $2}' /proc/loadavg)
    load_15min=$(awk '{print $3}' /proc/loadavg)
    
    # Get number of CPU cores
    if [ -f /proc/cpuinfo ]; then
        cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    else
        cpu_cores=$(nproc 2>/dev/null || echo "1")
    fi
    
    load_percent=$(awk "BEGIN {printf \"%.1f\", ($load_1min/$cpu_cores)*100}")
    
    echo -e "  ${YELLOW}📈 Load Average:${NC} $load_1min (1m) | $load_5min (5m) | $load_15min (15m)"
    echo -e "  ${YELLOW}💻 CPU Cores:${NC}    $cpu_cores"
    echo -e "  ${YELLOW}📊 Load %:${NC}        ${load_percent}% (of max capacity)"
    
    # Load warnings
    load_warn_threshold=$(awk "BEGIN {printf \"%.2f\", $cpu_cores * $LOAD_WARN_MULTIPLIER}")
    if compare_gt "$load_1min" "$load_warn_threshold"; then
        echo -e "  ${RED}⚠️  WARNING: System overloaded!${NC}"
    elif compare_gt "$load_percent" "$LOAD_NOTICE_PCT"; then
        echo -e "  ${YELLOW}⚠️  NOTICE: High system load${NC}"
    fi
    
    # Show CPU usage using a short interval sample
    if [ -f /proc/stat ]; then
        cpu_usage=$(get_cpu_usage_percent)
        echo -e "  ${CYAN}⚡ CPU Usage:${NC}    ${cpu_usage}% (1s sample)"
    fi
else
    echo -e "  ${RED}❌ Load information not available${NC}"
fi
echo

# Disk Usage
echo -e "${BOLD}${GREEN}💿 DISK USAGE${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"

if command_exists df; then
    # Show main filesystems, excluding temporary and special filesystems
    df -hPT 2>/dev/null | tail -n +2 | while read -r filesystem fs_type size used avail use_percent mount; do
        if is_ignored_fs_type "$fs_type"; then
            continue
        fi
        
        # Clean up percentage (remove %)
        clean_percent=$(echo "$use_percent" | tr -d '%')
        
        echo -e "  ${YELLOW}📁 $mount${NC} ($filesystem):"
        echo -e "     Size: $size | Used: $used | Available: $avail | Usage: $use_percent"
        
        # Disk usage warnings
        if [ "$clean_percent" -gt "$DISK_CRITICAL_PCT" ]; then
            echo -e "     ${RED}🚨 CRITICAL: Disk critically full!${NC}"
        elif [ "$clean_percent" -gt "$DISK_WARN_PCT" ]; then
            echo -e "     ${RED}⚠️  WARNING: Disk almost full!${NC}"
        elif [ "$clean_percent" -gt "$DISK_NOTICE_PCT" ]; then
            echo -e "     ${YELLOW}⚠️  NOTICE: Disk usage above ${DISK_NOTICE_PCT}%${NC}"
        fi
    done
    
    # Show inodes usage for root filesystem
    if inode_info=$(df -i / 2>/dev/null | tail -1); then
        inode_used=$(echo "$inode_info" | awk '{print $5}' | tr -d '%')
        if [ "$inode_used" -gt "$INODE_NOTICE_PCT" ]; then
            echo -e "  ${YELLOW}📊 Inode Usage:${NC} ${inode_used}%"
            if [ "$inode_used" -gt "$INODE_WARN_PCT" ]; then
                echo -e "     ${RED}⚠️  WARNING: High inode usage!${NC}"
            fi
        fi
    fi
else
    echo -e "  ${RED}❌ Disk monitoring not available${NC}"
fi
echo

# System Problems (Munin)
echo -e "${BOLD}${GREEN}⚠️  SYSTEM STATUS${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"

munin_problems_found=false
if command_exists w3m && [ -f /var/cache/munin/www/problems.html ]; then
    if problem_data=$(w3m -dump /var/cache/munin/www/problems.html 2>/dev/null); then
        critical=$(echo "$problem_data" | grep -o "Critical ([0-9]*)" | grep -o "[0-9]*" | head -1)
        warning=$(echo "$problem_data" | grep -o "Warning ([0-9]*)" | grep -o "[0-9]*" | head -1)
        unknown=$(echo "$problem_data" | grep -o "Unknown ([0-9]*)" | grep -o "[0-9]*" | head -1)
        
        echo -e "  ${RED}🔴 Critical Issues:${NC} ${critical:-0}"
        echo -e "  ${YELLOW}🟡 Warnings:${NC}        ${warning:-0}"
        echo -e "  ${BLUE}🔵 Unknown:${NC}         ${unknown:-0}"
        
        if [ "${critical:-0}" -gt 0 ]; then
            echo -e "  ${RED}❌ ATTENTION: Critical issues detected!${NC}"
        elif [ "${warning:-0}" -gt 0 ]; then
            echo -e "  ${YELLOW}⚠️  WARNING: Issues require attention${NC}"
        else
            echo -e "  ${GREEN}✅ All systems operational${NC}"
        fi
        munin_problems_found=true
    fi
fi

if [ "$munin_problems_found" = false ]; then
    # Basic system health checks
    echo -e "  ${YELLOW}📊 Basic System Health Check:${NC}"
    
    # Check if system is responsive
    if uptime_info=$(uptime -p 2>/dev/null); then
        echo -e "     ${GREEN}✅ System responsive ($uptime_info)${NC}"
    fi
    
    # Check critical services
    services_ok=0
    services_total=0
    for service_group in "ssh:sshd" "cron:crond"; do
        service_name=""
        IFS=':' read -r primary alt <<< "$service_group"
        if service_exists "$primary"; then
            service_name="$primary"
        elif service_exists "$alt"; then
            service_name="$alt"
        fi

        if [ -z "$service_name" ]; then
            continue
        fi

        services_total=$((services_total + 1))
        if service_is_active "$service_name"; then
            services_ok=$((services_ok + 1))
        fi
    done
    
    if [ "$services_total" -eq 0 ]; then
        echo -e "     ${CYAN}🔧 Critical services: no known service manager detected${NC}"
        echo -e "  ${YELLOW}⚠️  Skipped service checks on this system${NC}"
    else
        echo -e "     ${CYAN}🔧 Critical services: $services_ok/$services_total running${NC}"
        
        if [ "$services_ok" -eq "$services_total" ]; then
            echo -e "  ${GREEN}✅ Basic health check passed${NC}"
        else
            echo -e "  ${YELLOW}⚠️  Some services may need attention${NC}"
        fi
    fi
fi
echo

# Munin Reports (only if Munin is available)
if [ -d /var/cache/munin/www ]; then
    echo -e "${BOLD}${PURPLE}📈 DETAILED REPORTS${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}Network:${NC} w3m -dump /var/cache/munin/www/network-day.html"
    echo -e "  ${CYAN}System:${NC}  w3m -dump /var/cache/munin/www/system-day.html"
    echo -e "  ${CYAN}Monthly:${NC} w3m -dump /var/cache/munin/www/network-month.html"
    echo -e "  ${CYAN}All:${NC}     w3m -dump /var/cache/munin/www/index.html"
    echo
fi

# System Information Summary
echo -e "${BOLD}${PURPLE}📋 SYSTEM SUMMARY${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"
echo -e "  ${CYAN}OS:${NC}       $(uname -s) $(uname -r)"
echo -e "  ${CYAN}Arch:${NC}     $(uname -m)"
if [ -f /etc/os-release ]; then
    os_name=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    echo -e "  ${CYAN}Distro:${NC}   $os_name"
fi
echo -e "  ${CYAN}Shell:${NC}    $SHELL"
echo -e "  ${CYAN}User:${NC}     $(whoami)"
echo

echo -e "${BOLD}${CYAN}💡 TIP: Export BANDWIDTH_LIMIT_TB to match your provider plan (default: 32TB)${NC}"
echo -e "${BOLD}${CYAN}🔄 Usage: ./munin-check.sh ${NC}"
echo -e "${BOLD}${CYAN}📅 Monthly data resets automatically on the 1st of each month${NC}"
