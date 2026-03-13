
#!/bin/bash

arch=$(uname -m)

check_url() {
  local url="$1"

  if ! curl --output /dev/null --silent --head --fail "$url"; then
    echo "URL is invalid or unreachable: $url"
    exit 1
  else
    return 0
  fi
}

copy_and_notify() {
  local src="$1"
  local dst="$2"

  if [[ ! -e "$src" ]]; then
    echo "$src doesn't exist, skipping..."
    return
  fi

  echo "Copying $src to $dst"
  if ! sudo cp -rp "$src" "$dst"; then
    echo "Error: failed to copy '$src' to '$dst'" >&2
    exit 1
  fi
}

if [ "$(id -u)" -eq 0 ]; then
    echo "This script is not meant to be run as root."
    echo "It will create a home directory inside the rootfs for your current user, and if that user is root, this might not be what you want."
    read -p "Are you sure you want to continue as root? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

if [ "$arch" != "riscv64" ]; then
    echo "You are not on 64-bit RISC-V. felix86 only works on 64-bit RISC-V."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is not installed. Please install it and try again."
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "Error: tar is not installed. Please install it and try again."
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: unzip is not installed. Please install it and try again."
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is not installed. Please install it and try again."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is not installed. Please install it and try again."
    echo "On Ubuntu/Debian: sudo apt install jq"
    echo "On Arch: sudo pacman -S jq"
    echo "On Fedora: sudo dnf install jq"
    echo "On openSUSE: sudo zypper install jq"
    exit 1
fi

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    echo "Error: \$HOME is not set or not a valid directory."
    exit 1
fi

if [ -z "$USER" ]; then
    echo "\$USER is not set"
    exit 1
fi

check_url "https://cdn.felix86.com/rootfs/meta.json"
json=$(curl -s https://cdn.felix86.com/rootfs/meta.json)
mapfile -t names < <(jq -r 'to_entries[].key' <<< "$json")
default_index=$(jq -r 'to_entries | map(.value.recommended) | index(true)' <<< "$json")

echo "┌───────────────────────────────────────┐"
echo "│   felix86 Rootfs installer            │"
echo "├───────────────────────────────────────┤"
echo "│                                       │"
echo "│  Please choose the rootfs you'd       │"
echo "│  like to install                      │"
echo "│                                       │"
echo "└───────────────────────────────────────┘"
echo

i=1
for name in "${names[@]}"; do
    size=$(jq -r --arg n "$name" '.[$n].size' <<< "$json")
    recommended=$(jq -r --arg n "$name" '.[$n].recommended' <<< "$json")

    if [[ "$recommended" == "true" ]]; then
        printf " %d) %-25s %s\n" $i "$name" "[Size: $size] [Recommended]"
    else
        printf " %d) %-25s %s\n" $i "$name" "[Size: $size]"
    fi
    ((i++))
done

echo " $i) Enter custom path"
custom_index=$i
echo

while true; do
    read -p "Choose an option (default: ${names[default_index]}): " choice

    if [[ -z "$choice" ]]; then
        choice=$(($default_index+1))
    fi

    if [[ "$choice" == "$custom_index" ]]; then
        echo "You selected to use your own rootfs."
        echo "Please specify the absolute path to your rootfs"
        read -p "Path: " line
        felix86 --set-rootfs "$line"
        echo "Please make sure to properly copy relevant files in your rootfs, if you haven't already. See https://felix86.com/docs/devs/building-instructions/#important-files for more info" 
        NEW_ROOTFS="$line"
        break
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < custom_index )); then
        selected="${names[choice-1]}"
        selected_url=$(jq -r --arg n "$selected" '.[$n].url' <<< "$json")
        read -p "Installation path for $selected [default: $INSTALLATION_DIR/rootfs]: " NEW_ROOTFS
        DEFAULT_ROOTFS=$INSTALLATION_DIR/rootfs
        NEW_ROOTFS=${NEW_ROOTFS:-$DEFAULT_ROOTFS}
        NEW_ROOTFS=$(eval echo "$NEW_ROOTFS")
        if [ ! -e "$NEW_ROOTFS" ] || [ -d "$NEW_ROOTFS" ] && [ -z "$(ls -A "$NEW_ROOTFS" 2> /dev/null)" ]; then
        echo "Checking if $selected_url is live..."
        check_url $selected_url
        echo "Installing rootfs to $NEW_ROOTFS"
        echo "Creating rootfs directory..."
        sudo mkdir -p "$NEW_ROOTFS"
        if ! sudo -u nobody test -r "$NEW_ROOTFS"; then
            echo -e "\033[33mWarning: Different users cannot access this rootfs path. This may lead into problems with programs that try to switch to a different user.\033[0m"
            echo "It is not recommended you install the rootfs in paths not accessible by all users, such as the home directory."
            read -p "Are you sure you want to install the rootfs at $NEW_ROOTFS? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
        echo "Downloading $selected..."
        curl -L $selected_url | sudo tar --same-owner -xz -C "$NEW_ROOTFS"
        sudo chown 0:0 "$NEW_ROOTFS"
        sudo mkdir "$NEW_ROOTFS/home"
        CURRENT_USER=$(whoami)
        echo "Creating home directory for $CURRENT_USER..." 
        sudo mkdir "$NEW_ROOTFS/home/$CURRENT_USER"
        sudo chown $CURRENT_USER:$CURRENT_USER "$NEW_ROOTFS/home/$CURRENT_USER"
        echo "Creating /dev..."
        sudo mkdir -p "$NEW_ROOTFS/dev"
        echo "Creating /proc..."
        sudo mkdir -p "$NEW_ROOTFS/proc"
        echo "Creating /sys..."
        sudo mkdir -p "$NEW_ROOTFS/sys"
        echo "Creating /run..."
        sudo mkdir -p "$NEW_ROOTFS/run"
        echo "Creating /tmp..."
        sudo mkdir -p "$NEW_ROOTFS/tmp"
        echo "$selected was downloaded and extracted in $NEW_ROOTFS"
        echo "Copying important files to rootfs..."
        mkdir -p "$NEW_ROOTFS/var/lib"
        mkdir -p "$NEW_ROOTFS/etc"
        copy_and_notify "/etc/mtab" "$NEW_ROOTFS/etc/mtab"
        copy_and_notify "/etc/passwd" "$NEW_ROOTFS/etc/passwd"
        copy_and_notify "/etc/passwd-" "$NEW_ROOTFS/etc/passwd-"
        copy_and_notify "/etc/group" "$NEW_ROOTFS/etc/group"
        copy_and_notify "/etc/group-" "$NEW_ROOTFS/etc/group-"
        copy_and_notify "/etc/shadow" "$NEW_ROOTFS/etc/shadow"
        copy_and_notify "/etc/shadow-" "$NEW_ROOTFS/etc/shadow-"
        copy_and_notify "/etc/gshadow" "$NEW_ROOTFS/etc/gshadow"
        copy_and_notify "/etc/gshadow-" "$NEW_ROOTFS/etc/gshadow-"
        copy_and_notify "/etc/hosts" "$NEW_ROOTFS/etc/hosts"
        copy_and_notify "/etc/hostname" "$NEW_ROOTFS/etc/hostname"
        copy_and_notify "/etc/timezone" "$NEW_ROOTFS/etc/timezone"
        copy_and_notify "/etc/localtime" "$NEW_ROOTFS/etc/localtime"
        copy_and_notify "/etc/fstab" "$NEW_ROOTFS/etc/fstab"
        copy_and_notify "/etc/subuid" "$NEW_ROOTFS/etc/subuid"
        copy_and_notify "/etc/subgid" "$NEW_ROOTFS/etc/subgid"
        copy_and_notify "/etc/machine-id" "$NEW_ROOTFS/etc/machine-id"
        copy_and_notify "/etc/resolv.conf" "$NEW_ROOTFS/etc/resolv.conf"
        copy_and_notify "/etc/sudoers" "$NEW_ROOTFS/etc/sudoers"
        echo "Done!"
        felix86 --set-rootfs "$NEW_ROOTFS"
        else
        echo "$NEW_ROOTFS already exists and is not empty, I won't unpack the rootfs there"
        exit 1
        fi
        break
    else
        echo "Invalid choice, try again."
    fi
done