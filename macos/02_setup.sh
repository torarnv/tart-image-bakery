#!/bin/bash

# This script is run from within macOS Recovery mode,
# and sets up macOS without involving Setup Assistant.

echo -e "\033c"; cat << 'EOF'
            _       _ ____            _     _
  _ __ ___ (_)_ __ (_) __ ) _   _  __| | __| |_   _
 | '_ ` _ \| | '_ \| |  _ \| | | |/ _` |/ _` | | | |
 | | | | | | | | | | | |_) | |_| | (_| | (_| | |_| |
 |_| |_| |_|_|_| |_|_|____/ \__,_|\__,_|\__,_|\__, |
                                              |___/
EOF
echo -n " macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo -n " | $(sysctl -n machdep.cpu.brand_string)"; echo; echo

# Logging
exec 3>&1
logfile=$(mktemp)
exec > "$logfile" 2>&1
log() { echo "$*" >&3; }
trap 'log "[!] Setup failed. Full log below:" && cat "$logfile" >&3' ERR
set -ex

# Set up user account
username=${USERNAME:-admin}
password=${PASSWORD:-admin}

log "[*] Adding user '$username' to directory services"

dscl() {
    command dscl \
        -f "/Volumes/Data/private/var/db/dslocal/nodes/Default" \
        localhost "$@"
}
user_path="/Local/Default/Users/$username"
uid="501"; gid="20"

dscl -create "$user_path"
dscl -create "$user_path" UserShell "/bin/zsh"
dscl -create "$user_path" RealName "$username"
dscl -create "$user_path" UniqueID "$uid"
dscl -create "$user_path" PrimaryGroupID "$gid"
dscl -create "$user_path" NFSHomeDirectory "/Users/$username"
dscl -passwd "$user_path" "$password"
uuid=$(dscl -read "$user_path" GeneratedUID | awk '{print $2}')

for group in staff admin; do
    dscl -append /Local/Default/Groups/$group GroupMembership "$username"
    dscl -append /Local/Default/Groups/$group GroupMembers "$uuid"
done

# Set up standard home directory structure
# Ownership is established at the end
cp -R "/System/Library/User Template/Non_localized" "/Volumes/Data/Users/$username"

# Enable auto-login
log "[*] Enabling auto-login for '$username'"
kcpassword() {
    local passwd="$1"

    # The magic 11-byte XOR key
    local key=(125 137 82 35 210 188 221 234 163 185 31)
    local key_len=${#key[@]}
    local padding_multiple=12

    # Convert password to byte array, with zero terminator
    local passwd_bytes=()
    local i
    for ((i = 0; i < ${#passwd}; i++)); do
        passwd_bytes+=($(printf '%d' "'${passwd:$i:1}"))
    done
    passwd_bytes+=(0)

    # Pad to multiple of 12 with zeros
    local passwd_len=${#passwd_bytes[@]}
    local remainder=$((passwd_len % padding_multiple))
    if ((remainder > 0)); then
        local padding=$((padding_multiple - remainder))
        for ((i = 0; i < padding; i++)); do
            passwd_bytes+=(0)
        done
    fi

    # XOR each byte with the corresponding key byte
    local result=()
    for ((i = 0; i < ${#passwd_bytes[@]}; i++)); do
        result+=($((passwd_bytes[i] ^ key[i % key_len])))
    done

    # Output as hex (for piping to xxd -r -p)
    for byte in "${result[@]}"; do
        printf '%02x' "$byte"
    done
}
kcpassword_file="/Volumes/Data/private/etc/kcpassword"
(set +x; kcpassword "$password") | "/Volumes/Macintosh HD/usr/bin/xxd" -r -p > "$kcpassword_file"
chmod 600 "$kcpassword_file"
login_window_plist="/Volumes/Data/Library/Preferences/com.apple.loginwindow.plist"
plutil -create binary1 $login_window_plist
plutil -insert autoLoginUser -string admin $login_window_plist

# Skip Setup Assistant
log "[*] Skipping Setup Assistant"
setup_assistant_plist="/Volumes/Data/Users/$username/Library/Preferences/com.apple.SetupAssistant.plist"
mkdir -p "${setup_assistant_plist%/*}"
plutil -create binary1 "$setup_assistant_plist"
sw_build_version=$(sw_vers -buildVersion)
plutil -insert LastSeenBuddyBuildVersion -string "$sw_build_version" "$setup_assistant_plist"
touch "/Volumes/Data/private/var/db/.AppleSetupDone"

# Enable SSH
log "[*] Enabling SSH service"
launchd_disabled_plist="/Volumes/Data/private/var/db/com.apple.xpc.launchd/disabled.plist"
plutil -create binary1 $launchd_disabled_plist
plutil -insert "com\.openssh\.sshd" -bool false $launchd_disabled_plist

# Enable VNC
log "[*] Enabling VNC service"
plutil -insert "com\.apple\.screensharing" -bool false $launchd_disabled_plist

# Disable SIP if requested
if [[ "$DISABLE_SIP" = "true" ]]; then
    log "[*] Disabling System Integrity Protection..."

    # Disabling SIP in RecoveryOS before first
    # boot requires some extra steps.

    # Propagate user to Preboot volume's AdminUserRecoveryInfo.plist,
    # so csrutil recognizes it as being "authorized for recovery".
    log "  [*] Updating pre-boot volume"
    diskutil apfs updatePreboot /Volumes/Data

    # Tahoe has what seems like a bug in storagekitd, where it will copy
    # secureaccesstoken.plist during updatePreboot using a .nofollow prefix,
    # which doesn't work due to 'var' being a symlink to 'private/var'.
    # The bug has been fixed in macOS 26.4 (FB21708839)
    if sw_vers --productVersion | grep -q "^26\.[0-3]"; then
        # We can copy it manually though
        log "  [*] Manually copying secureaccesstoken.plist to preboot"
        data_volume_uuid=$(diskutil info -plist /Volumes/Data/ | plutil -extract VolumeUUID raw -)
        diskutil mount Preboot # In some cases the volume has been unmounted
        cp "/Volumes/Macintosh HD/var/db/dslocal/nodes/Default/secureaccesstoken.plist" \
           "/Volumes/Preboot/$data_volume_uuid/var/db"
    fi

    # Finally, restart authd so it picks up our new user from the
    # volume's AllUsersInfo.plist, populating the PreloginUserDb.
    log "  [*] Restarting authorization daemon"
    launchctl kickstart -k system/com.apple.authd

    # We're now ready to disable SIP
    echo y | csrutil disable
    # Boot command will type admin password
    csrutil status | grep -q disabled
    # Wipe password prompt after completion
    echo -ne "\033[F\033[2K" >&3
    log "  [+] SIP disabled successfully"
fi

log "[*] Finalizing setup"

# Make sure the user we've created owns everything in its home directory
chown -R "$uid:$gid" "/Volumes/Data/Users/$username"

# Unmount data volume explicitly, to ensure persistence even
# when we skip provisioning and the Packer Tart plugin kills
# the VM directly.
diskutil unmount /Volumes/Data

log "[+] Unattended setup completed successfully"; echo >&3
