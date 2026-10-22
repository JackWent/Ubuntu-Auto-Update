#!/bin/bash
# Enhanced Ubuntu Auto Patch Script with Phased Updates Support
# Define a file to track progress
PROGRESS_FILE="/var/log/update-script-progress"

# Options for every apt call that changes packages:
# - wait up to 10 minutes for another apt or unattended-upgrades run instead of failing
# - keep existing config files when a package ships a new default, without prompting
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Count failed apt steps, so a bad run says so instead of "completed successfully".
ERRORS=0
apt_step() {
    if ! sudo DEBIAN_FRONTEND=noninteractive apt "${APT_OPTS[@]}" "$@"; then
        echo "ERROR: apt $* failed"
        ERRORS=$((ERRORS + 1))
    fi
}

# Ubuntu flags a needed reboot with /var/run/reboot-required. Debian doesn't, so there
# a newer installed kernel than the running one also counts. KERNEL_MARK remembers the
# kernel we last rebooted for, so a system that boots an older kernel can't reboot-loop.
KERNEL_MARK="/var/lib/update-script-kernel"
reboot_needed() {
    [ -f /var/run/reboot-required ] && return 0
    [ -e /usr/share/update-notifier/notify-reboot-required ] && return 1
    local newest
    newest=$(find /boot -maxdepth 1 -name "vmlinuz-*" 2>/dev/null | sed "s#^/boot/vmlinuz-##" | sort -V | tail -n 1)
    if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && [ "$(cat "$KERNEL_MARK" 2>/dev/null)" != "$newest" ]; then
        echo "$newest" > "$KERNEL_MARK"
        return 0
    fi
    return 1
}

# Function to check if a reboot is required
check_reboot() {
    if reboot_needed; then
        echo "Reboot required. Rebooting now..."
        echo "step1_reboot" > $PROGRESS_FILE
        reboot
        exit 0
    fi
}

# Function to check the progress and continue where left off
check_progress() {
    if [ -f $PROGRESS_FILE ]; then
        PROGRESS=$(cat $PROGRESS_FILE)
        case $PROGRESS in
            "step1_reboot")
                echo "Continuing after first reboot..."
                step2_install_updates
                ;;
            "step2_updates")
                echo "Continuing after updates..."
                step3_install_kept_back
                ;;
            "step3_kept_back")
                echo "Continuing after installing kept-back packages..."
                step4_install_phased_updates
                ;;
            "step4_phased")
                echo "Continuing after installing phased updates..."
                check_reboot_after_updates
                ;;
            *)
                echo "Unknown progress state, starting from the beginning."
                start_script
                ;;
        esac
    else
        start_script
    fi
}

# Function to start the script
start_script() {
    check_reboot
    step2_install_updates
}

# Function to perform updates
step2_install_updates() {
    echo "Updating package lists..."
    sudo apt update
    echo "Upgrading installed packages..."
    # Set non-interactive frontend to avoid prompts
    apt_step upgrade -y
    echo "step2_updates" > $PROGRESS_FILE
    step3_install_kept_back
}

# Function to install kept-back packages
step3_install_kept_back() {
    echo "Installing kept-back packages..."
    # Set non-interactive frontend to avoid prompts
    apt_step dist-upgrade -y
    echo "step3_kept_back" > $PROGRESS_FILE
    step4_install_phased_updates
}

# Function to install phased updates
step4_install_phased_updates() {
    echo "Checking for phased updates..."
    
    # Check for packages that have been kept back due to phasing
    KEPT_BACK=$(apt list --upgradable 2>/dev/null | grep -v "^WARNING" | grep -v "^Listing" | wc -l)
    
    if [ "$KEPT_BACK" -gt 0 ]; then
        echo "Found $KEPT_BACK packages that may be held back due to phasing."
        echo "Attempting to install all available updates including phased ones..."
        
        # Method 1: Use the correct apt option to bypass phasing
        echo "Running apt upgrade with phased updates included..."
        apt_step -o APT::Get::Always-Include-Phased-Updates=true upgrade -y
        
        # Method 2: Alternative using dist-upgrade with phasing override
        echo "Running dist-upgrade with phased updates included..."
        apt_step -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
        
        # Method 3: If the above don't work, try installing specific packages
        echo "Checking for any remaining upgradable packages..."
        REMAINING_PACKAGES=$(apt list --upgradable 2>/dev/null | grep -v "^WARNING" | grep -v "^Listing" | awk -F'/' '{print $1}')
        
        if [ -n "$REMAINING_PACKAGES" ]; then
            echo "Installing remaining packages individually..."
            # apt install marks a package as manually installed; remember which were
            # automatic so autoremove can still clean them up later.
            AUTO_BEFORE=$(apt-mark showauto 2>/dev/null)
            for package in $REMAINING_PACKAGES; do
                echo "Installing $package..."
                sudo DEBIAN_FRONTEND=noninteractive apt "${APT_OPTS[@]}" -o APT::Get::Always-Include-Phased-Updates=true install -y "$package" 2>/dev/null || echo "Failed to install $package (held packages are skipped)"
            done
            for package in $REMAINING_PACKAGES; do
                if grep -qxF "$package" <<< "$AUTO_BEFORE"; then
                    sudo apt-mark auto "$package" > /dev/null 2>&1 || true
                fi
            done
        fi
        
    else
        echo "No packages appear to be held back."
    fi
    
    echo "step4_phased" > $PROGRESS_FILE
    check_reboot_after_updates
}

# Function to check if a reboot is required after updates
check_reboot_after_updates() {
    check_reboot
    cleanup
}

# Function to clean up unnecessary packages
cleanup() {
    echo "Cleaning up unnecessary packages..."
    apt_step autoremove -y
    apt_step autoclean
    
    # Final check for any remaining updates
    echo "Performing final update check..."
    sudo apt update
    REMAINING_UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "^WARNING" | grep -v "^Listing" | wc -l)
    
    if [ "$REMAINING_UPDATES" -gt 0 ]; then
        echo "Note: $REMAINING_UPDATES updates may still be available (possibly still phased)."
        echo "To see them, run: apt list --upgradable"
    else
        echo "System is fully up to date."
    fi
    
    if [ "$ERRORS" -gt 0 ]; then
        echo "Script finished with $ERRORS failed apt step(s). Check the log above."
        rm -f $PROGRESS_FILE
        exit 1
    fi
    echo "Script completed successfully."
    rm -f $PROGRESS_FILE
}

# Function to show current phasing status (optional utility)
show_phasing_info() {
    echo "Current phasing information:"
    echo "APT_CONFIG_PHASING: ${APT_CONFIG_PHASING:-not set}"
    echo "Available phased updates:"
    apt list --upgradable 2>/dev/null | grep -E "\[.*phased.*\]" || echo "None found"
}

# Uncomment the next line to see phasing info before starting
# show_phasing_info

# Start or continue the script
check_progress