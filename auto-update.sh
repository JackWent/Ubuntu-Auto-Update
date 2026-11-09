#!/bin/bash
# Enhanced Ubuntu Auto Patch Script with Phased Updates Support

# Runs as root (root's crontab). apt is called directly rather than through sudo: an autoremove
# after a release upgrade can remove sudo, which would then make every apt step fail.
if [ "$(id -u)" -ne 0 ]; then
    echo "auto-update.sh must run as root" >&2
    exit 1
fi
# STATE_DIR keeps what the run needs across reboots: its progress, the failed-step count, and what was
# installed before the run. It is under /var/lib (root only), because /var/log can be written by other
# groups and root follows symlinks there.
STATE_DIR="/var/lib/update-script"
mkdir -p "$STATE_DIR"
# Define a file to track progress
PROGRESS_FILE="$STATE_DIR/progress"

# Options for every apt call that changes packages:
# - wait up to 10 minutes for another apt or unattended-upgrades run instead of failing
# - keep existing config files when a package ships a new default, without prompting
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Discord report at the end of each run that changed something or failed (quiet otherwise).
# The webhook is read from HOOK_FILE (root-only); without it, no report is sent.
HOOK_FILE="/etc/auto-update/discord-webhook"
BEFORE_FILE="$STATE_DIR/packages-before"
REBOOTS_FILE="$STATE_DIR/reboots"
FAILED_FILE="$STATE_DIR/failed-steps"

# Count failed apt steps, so a bad run says so instead of "completed successfully".
# The count is kept in a file because a run can reboot part way and carry on after.
ERRORS_FILE="$STATE_DIR/errors"

# Older versions kept these two files in /var/log. Take over a real file left there by a run that was
# interrupted by a reboot (never a symlink), then remove whatever is left at the old path.
for name in progress errors; do
    old="/var/log/update-script-$name"
    if [ -f "$old" ] && [ ! -L "$old" ] && [ ! -e "$STATE_DIR/$name" ]; then
        mv "$old" "$STATE_DIR/$name"
    fi
    rm -f "$old"
done
ERRORS=$(cat "$ERRORS_FILE" 2>/dev/null || echo 0)
[[ "$ERRORS" =~ ^[0-9]+$ ]] || ERRORS=0
apt_step() {
    if ! DEBIAN_FRONTEND=noninteractive apt "${APT_OPTS[@]}" "$@"; then
        echo "ERROR: apt $* failed"
        mkdir -p "$STATE_DIR" && echo "apt $*" >> "$FAILED_FILE"
        ERRORS=$((ERRORS + 1))
        echo "$ERRORS" > "$ERRORS_FILE"
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
        mkdir -p "$STATE_DIR"
        echo $(( $(cat "$REBOOTS_FILE" 2>/dev/null || echo 0) + 1 )) > "$REBOOTS_FILE"
        echo "step1_reboot" > "$PROGRESS_FILE"
        reboot
        exit 0
    fi
}

# Function to check the progress and continue where left off
check_progress() {
    if [ -f "$PROGRESS_FILE" ]; then
        PROGRESS=$(cat "$PROGRESS_FILE")
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
    # A fresh run: remember the installed versions so the report can list what changed.
    mkdir -p "$STATE_DIR"
    dpkg-query -W -f='${Package} ${Version}\n' > "$BEFORE_FILE" 2>/dev/null
    echo 0 > "$REBOOTS_FILE"
    rm -f "$FAILED_FILE"
    check_reboot
    step2_install_updates
}

# Function to perform updates
step2_install_updates() {
    echo "Updating package lists..."
    apt_step update
    echo "Upgrading installed packages..."
    # Set non-interactive frontend to avoid prompts
    apt_step upgrade -y
    echo "step2_updates" > "$PROGRESS_FILE"
    step3_install_kept_back
}

# Function to install kept-back packages
step3_install_kept_back() {
    echo "Installing kept-back packages..."
    # Set non-interactive frontend to avoid prompts
    apt_step dist-upgrade -y
    echo "step3_kept_back" > "$PROGRESS_FILE"
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
                DEBIAN_FRONTEND=noninteractive apt "${APT_OPTS[@]}" -o APT::Get::Always-Include-Phased-Updates=true install -y "$package" 2>/dev/null || echo "Failed to install $package (held packages are skipped)"
            done
            for package in $REMAINING_PACKAGES; do
                if grep -qxF "$package" <<< "$AUTO_BEFORE"; then
                    apt-mark auto "$package" > /dev/null 2>&1 || true
                fi
            done
        fi
        
    else
        echo "No packages appear to be held back."
    fi
    
    echo "step4_phased" > "$PROGRESS_FILE"
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
    apt_step update
    REMAINING_UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "^WARNING" | grep -v "^Listing" | wc -l)
    
    if [ "$REMAINING_UPDATES" -gt 0 ]; then
        echo "Note: $REMAINING_UPDATES updates may still be available (possibly still phased)."
        echo "To see them, run: apt list --upgradable"
    else
        echo "System is fully up to date."
    fi
    
    rm -f "$ERRORS_FILE"
    report "$REMAINING_UPDATES"
    rm -f "$BEFORE_FILE" "$REBOOTS_FILE" "$FAILED_FILE"
    if [ "$ERRORS" -gt 0 ]; then
        echo "Script finished with $ERRORS failed apt step(s). Check the log above."
        rm -f "$PROGRESS_FILE"
        exit 1
    fi
    echo "Script completed successfully."
    rm -f "$PROGRESS_FILE"
}

# JSON string body from stdin (quotes, backslashes, tabs, newlines).
json_text() {
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' | awk '{printf "%s\\n", $0}'
}

# Post the run's result to Discord: what changed (old -> new), reboots, what's still pending,
# failed steps. Nothing is sent for a run that installed nothing and had no errors.
report() {
    local remaining="$1" url changes removed reboots failed title colour summary body
    url=$(cat "$HOOK_FILE" 2>/dev/null) || return 0
    [ -n "$url" ] || return 0
    if [ -f "$BEFORE_FILE" ]; then
        changes=$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | awk 'NR==FNR {old[$1]=$2; next}
            !($1 in old) {print $1 " (new) " $2; next} old[$1] != $2 {print $1 " " old[$1] " -> " $2}' "$BEFORE_FILE" -)
        removed=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk 'NR==FNR {now[$1]=1; next} !($1 in now)' - "$BEFORE_FILE" | wc -l)
    fi
    reboots=$(cat "$REBOOTS_FILE" 2>/dev/null || echo 0)
    failed=$(cat "$FAILED_FILE" 2>/dev/null)
    if [ -z "$changes" ] && [ "$reboots" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
        return 0
    fi
    local n=0
    [ -n "$changes" ] && n=$(printf '%s\n' "$changes" | wc -l)
    if [ "$ERRORS" -gt 0 ]; then
        title="❌ $(hostname -s): patching had $ERRORS failed step(s)"; colour=15158332
    elif [ "${remaining:-0}" -gt 0 ]; then
        title="🩹 $(hostname -s) patched, $remaining still pending"; colour=16098851
    else
        title="🩹 $(hostname -s) patched"; colour=4437377
    fi
    summary="**$n package(s) updated**"
    [ "${removed:-0}" -gt 0 ] && summary="$summary · $removed removed"
    [ "$reboots" -gt 0 ] && summary="$summary · rebooted ${reboots}×"
    summary="$summary · ${remaining:-0} pending"
    body="$summary"
    [ -n "$failed" ] && body="$body"$'\n'"Failed: "$'\n'"\`\`\`"$'\n'"$failed"$'\n'"\`\`\`"
    if [ -n "$changes" ]; then
        body="$body"$'\n'"\`\`\`"$'\n'"$(printf '%s\n' "$changes" | head -40)"
        [ "$n" -gt 40 ] && body="$body"$'\n'"…and $((n - 40)) more"
        body="$body"$'\n'"\`\`\`"
    fi
    printf '{"embeds":[{"title":"%s","description":"%s","color":%s,"footer":{"text":"auto-update.sh · %s"},"timestamp":"%s"}],"allowed_mentions":{"parse":[]}}' \
        "$(printf '%s' "$title" | json_text | sed 's/\\n$//')" "$(printf '%s' "$body" | cut -c1-3800 | json_text)" "$colour" \
        "$(uname -r)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | curl -sS -m 15 -o /dev/null -H 'Content-Type: application/json' -d @- "$url" || echo "Discord report failed"
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