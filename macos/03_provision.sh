#!/bin/bash

# Minimal provisioning needed to build other services on top

set -e

# Enable passwordless sudo
echo ${PKR_VAR_password} | sudo -S -p '' sh -c "echo '${PKR_VAR_username} ALL=(ALL) NOPASSWD: ALL' | \
    EDITOR=tee visudo /etc/sudoers.d/${PKR_VAR_username}-nopasswd"

# Disable screensaver everywhere
sudo defaults write com.apple.screensaver loginWindowIdleTime 0
defaults -currentHost write com.apple.screensaver idleTime 0

# Prevent the VM from sleeping
sudo systemsetup -setdisplaysleep Off 2>/dev/null
sudo systemsetup -setsleep Off 2>/dev/null
sudo systemsetup -setcomputersleep Off 2>/dev/null

# Disable screen lock
until sysadminctl -screenLock status 2>&1 | grep -q "is off"; do
    sysadminctl -screenLock off -password ${PKR_VAR_password} \
        2>/dev/null || sleep 1
done

# Set host name based on VM name, and pretty computer name
sudo scutil --set LocalHostName $(echo ${PKR_VAR_vm_name} | sed 's/[^A-Za-z0-9-]/-/g')
sudo scutil --set ComputerName "macOS $(sw_vers --productVersion) VM"

# Prepare for Ansible provisioning
if [ -n "$PKR_VAR_ansible_playbook" ]; then
    # Ansible requires Python, so let's install Command Line Tools up front
    clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    sudo touch "${clt_placeholder}"

    echo "🔎 Finding latest Command Line Tools..."
    clt_label=""
    while [ -z "$clt_label" ]; do
        clt_label=$(softwareupdate --list 2>/dev/null |
                grep -A1 '\* Label: Command Line Tools' |
                paste - - |
                sed 's/.*\* Label: //; s/\tTitle:.*Version: /\t/' |
                sort -t$'\t' -k2 -V |
                tail -n1 |
                cut -f1)
    done

    echo "📦 Installing ${clt_label}..."
    sudo softwareupdate --install --no-scan --verbose "${clt_label}"
    sudo xcode-select --switch "/Library/Developer/CommandLineTools"

    sudo rm -f "${clt_placeholder}"
fi
