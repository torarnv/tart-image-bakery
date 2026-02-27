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
    # Ansible requires Python, so let's install the latest available version now
    LATEST=$(curl -s "https://www.python.org/api/v2/downloads/release/?version=3" | \
      perl -0 -MJSON::PP -e '
        my $data = JSON::PP->new->decode(do { local $/; <STDIN> });
        my ($r) = grep { $_->{is_latest} } @$data;
        print $r->{name} =~ s/Python //r;
      ')
    echo "Installing latest official Python version $LATEST..."
    curl -O "https://www.python.org/ftp/python/${LATEST}/python-${LATEST}-macos11.pkg" 2>&1
    sudo installer -verbose -pkg "python-${LATEST}-macos11.pkg" -target /
fi
