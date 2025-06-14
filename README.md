# VPS Usage Check

A comprehensive shell script for monitoring resource usage on your Ubuntu VPS servers, with special focus on tracking outgoing bandwidth against a 32TB monthly limit.

## Features

- **Network Traffic Monitoring**: Track inbound/outbound bandwidth with 32TB monthly limit alerts
- **Memory Usage**: Real-time memory and swap monitoring with usage warnings
- **CPU Load**: System load averages and CPU usage percentage
- **Disk Usage**: Filesystem usage monitoring with critical space alerts
- **System Health**: Basic service status and system responsiveness checks
- **Munin Integration**: Enhanced monitoring when Munin is available
- **Color-coded Output**: Easy-to-read status indicators and warnings

## Requirements

### Essential
- Ubuntu/Debian-based VPS
- Bash shell
- Basic system utilities (`df`, `awk`, `grep`)

### Optional (for enhanced features)
- **Munin**: For detailed historical monitoring and advanced metrics
- **w3m**: For parsing Munin HTML reports
- **bc**: For precise percentage calculations
- **systemctl**: For service status checking

## Installation

1. Clone or download the repository:
   ```bash
   git clone https://github.com/yourusername/vpsusagecheck.git
   cd vpsusagecheck
   ```

2. Make the script executable:
   ```bash
   chmod +x munin-check.sh
   ```

3. Run the script:
   ```bash
   ./munin-check.sh
   ```

## Usage

### Basic Usage
```bash
./munin-check.sh
```

### Setting up Regular Monitoring
Add to your crontab for automated monitoring:

```bash
# Edit crontab
crontab -e

# Add line for daily monitoring at 6 AM
0 6 * * * /path/to/vpsusagecheck/munin-check.sh > /var/log/vps-usage.log 2>&1

# Add line for hourly monitoring (optional)
0 * * * * /path/to/vpsusagecheck/munin-check.sh
```

### Email Alerts (Optional)
To receive email alerts when thresholds are exceeded:

```bash
# Install mailutils if not present
sudo apt-get install mailutils

# Create wrapper script for email alerts
cat > vps-monitor-alert.sh << 'EOF'
#!/bin/bash
OUTPUT=$(/path/to/vpsusagecheck/munin-check.sh)
echo "$OUTPUT"

# Send email if critical issues detected
if echo "$OUTPUT" | grep -q "WARNING\|CRITICAL"; then
    echo "$OUTPUT" | mail -s "VPS Alert: $(hostname)" your-email@domain.com
fi
EOF

chmod +x vps-monitor-alert.sh
```

## Understanding the Output

### Network Traffic Section
- **Inbound (Unlimited)**: Download traffic (not counted against limit)
- **Outbound (Counted)**: Upload traffic (counted against 32TB monthly limit)
- **Monthly Usage**: Percentage of 32TB limit used for outgoing traffic

### Warning Levels
- **🟢 Normal**: < 50% of any resource limit
- **🟡 Notice**: 50-80% of resource usage
- **🔴 Warning**: 80-95% of resource usage
- **🚨 Critical**: > 95% of resource usage

### Memory Usage
- **Total**: Total RAM available
- **Used**: Currently allocated memory
- **Available**: Memory available for new processes
- **Swap**: Virtual memory usage (if configured)

### System Load
- **Load Average**: 1, 5, and 15-minute load averages
- **Load %**: Load as percentage of CPU capacity
- **CPU Usage**: Current CPU utilization

## Troubleshooting

### Script Shows "Network monitoring not available"
1. Check if Munin is installed and running:
   ```bash
   sudo systemctl status munin-node
   ```

2. Install Munin if needed:
   ```bash
   sudo apt-get update
   sudo apt-get install munin munin-node
   ```

3. The script will fallback to `/proc/net/dev` for basic network stats

### Missing Munin Reports
1. Ensure Munin is generating reports:
   ```bash
   sudo -u munin munin-cron
   ```

2. Check Munin configuration:
   ```bash
   sudo nano /etc/munin/munin.conf
   ```

### Permission Issues
If you get permission errors:
```bash
# Add your user to necessary groups
sudo usermod -a -G adm,sys $(whoami)

# Or run with sudo for full system access
sudo ./munin-check.sh
```

### High Resource Usage Alerts
- **Memory > 90%**: Consider adding swap or upgrading RAM
- **Disk > 90%**: Clean up files or expand storage
- **Load > CPU cores**: Investigate running processes
- **Bandwidth > 80%**: Monitor traffic patterns closely

## Customization

### Modifying Bandwidth Limit
To change the 32TB monthly limit, edit the script:
```bash
# Find this line in munin-check.sh
monthly_limit_bytes=$((32 * 1099511627776))  # 32TB in bytes

# Change 32 to your limit in TB
monthly_limit_bytes=$((YOUR_LIMIT * 1099511627776))
```

### Adding Custom Checks
You can extend the script by adding custom monitoring sections:
```bash
# Add after existing monitoring sections
echo -e "${BOLD}${GREEN}🔧 CUSTOM MONITORING${NC}"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────${NC}"
# Your custom monitoring code here
```

## Files

- `munin-check.sh`: Main monitoring script
- `README.md`: This documentation
- `LICENSE`: GPL v3 license
- `CLAUDE.md`: Development guidelines for AI assistants

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly on Ubuntu systems
5. Submit a pull request

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Support

For issues, questions, or suggestions:
1. Check the troubleshooting section above
2. Search existing issues on GitHub
3. Create a new issue with system details and error messages

## Changelog

### v1.0.0
- Initial release with comprehensive VPS monitoring
- 32TB bandwidth limit tracking
- Munin integration with fallback options
- Color-coded output and alerts
- Memory, CPU, disk, and network monitoring
