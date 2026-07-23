#!/bin/bash
# Enhanced Ubuntu Auto Patch Script with Phased Updates Support
# Define a file to track progress
PROGRESS_FILE="/var/log/update-script-progress"

# Function to check if a reboot is required
check_reboot() {
    if [ -f /var/run/reboot-required ]; then
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
    sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
    echo "step2_updates" > $PROGRESS_FILE
    step3_install_kept_back
}

# Function to install kept-back packages
step3_install_kept_back() {
    echo "Installing kept-back packages..."
    # Set non-interactive frontend to avoid prompts
    sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y
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
        sudo DEBIAN_FRONTEND=noninteractive apt -o APT::Get::Always-Include-Phased-Updates=true upgrade -y
        
        # Method 2: Alternative using dist-upgrade with phasing override
        echo "Running dist-upgrade with phased updates included..."
        sudo DEBIAN_FRONTEND=noninteractive apt -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
        
        # Method 3: If the above don't work, try installing specific packages
        echo "Checking for any remaining upgradable packages..."
        REMAINING_PACKAGES=$(apt list --upgradable 2>/dev/null | grep -v "^WARNING" | grep -v "^Listing" | awk -F'/' '{print $1}')
        
        if [ -n "$REMAINING_PACKAGES" ]; then
            echo "Installing remaining packages individually..."
            for package in $REMAINING_PACKAGES; do
                echo "Installing $package..."
                sudo DEBIAN_FRONTEND=noninteractive apt -o APT::Get::Always-Include-Phased-Updates=true install -y "$package" 2>/dev/null || echo "Failed to install $package"
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
    sudo apt autoremove -y
    sudo apt autoclean
    
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