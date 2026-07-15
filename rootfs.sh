
#!/bin/bash

set -euo pipefail

INSTALLATION_DIR="/opt/felix86"

felix86_version_gte() {
    local required="$1"
    local version
    version=$(felix86 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    if [[ -z "$version" ]]; then
        return 1
    fi
    local req_major req_minor ver_major ver_minor
    IFS='.' read -r req_major req_minor <<< "$required"
    IFS='.' read -r ver_major ver_minor <<< "$version"
    if (( 10#$ver_major > 10#$req_major )) || (( 10#$ver_major == 10#$req_major && 10#$ver_minor >= 10#$req_minor )); then
        return 0
    fi
    return 1
}

set_rootfs() {
    local path="$1"
    if felix86_version_gte "26.08"; then
        sudo felix86 --set-config general.rootfs_path="$path"
    else
        felix86 --set-rootfs "$path"
    fi
}

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
    if ! whiptail --title "Warning" --yesno \
      "This script is not meant to be run as root.\n\nIt will create a home directory inside the rootfs for your current user, and if that user is root, this might not be what you want.\n\nAre you sure you want to continue as root?" \
      20 60; then
        exit 1
    fi
fi

if [ "$arch" != "riscv64" ]; then
    echo "You are not on 64-bit RISC-V. felix86 only works on 64-bit RISC-V."
    exit 1
fi

missing=()
for cmd in curl tar unzip sudo jq whiptail; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: missing required tools: ${missing[*]}"
    echo "  Ubuntu/Debian: sudo apt install ${missing[*]}"
    echo "  Arch:          sudo pacman -S ${missing[*]}"
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

max_name_width=0
for name in "${names[@]}"; do
    if (( ${#name} > max_name_width )); then
        max_name_width=${#name}
    fi
done

max_size_width=0
for i in "${!names[@]}"; do
    size=$(jq -r --arg n "${names[$i]}" '.[$n].size' <<< "$json")
    if (( ${#size} > max_size_width )); then
        max_size_width=${#size}
    fi
done

menu_items=()
default_tag=""
for i in "${!names[@]}"; do
    name="${names[$i]}"
    size=$(jq -r --arg n "$name" '.[$n].size' <<< "$json")
    recommended=$(jq -r --arg n "$name" '.[$n].recommended' <<< "$json")
    experimental=$(jq -r --arg n "$name" '.[$n].experimental // false' <<< "$json")
    local_num=$((i+1))
    tag=""
    if [[ "$recommended" == "true" ]]; then
        tag="(Recommended)"
        default_tag="${local_num})"
    elif [[ "$experimental" == "true" ]]; then
        tag="(Experimental)"
    fi
    entry=$(printf "%-${max_name_width}s  [%${max_size_width}s]  %s" "$name" "$size" "$tag")
    menu_items+=("${local_num})" "$entry")
done

custom_index=$(( ${#names[@]} + 1 ))
menu_items+=("${custom_index})" "Enter custom path")

menu_height=$(( ${#names[@]} + 3 ))
choice=$(whiptail --title "felix86 Rootfs Installer" \
    --menu "Choose the rootfs you'd like to install:" \
    20 75 $menu_height \
    "${menu_items[@]}" \
    --default-item "$default_tag" \
    3>&1 1>&2 2>&3) || exit 1
choice="${choice%)}"

if [[ "$choice" == "$custom_index" ]]; then
    line=$(whiptail --title "Custom rootfs" --inputbox \
      "Please specify the absolute path to your rootfs:" \
      10 60 3>&1 1>&2 2>&3) || exit 1
    set_rootfs "$line"
    whiptail --title "Note" --msgbox \
      "Please make sure to properly copy relevant files in your rootfs, if you haven't already.\n\nSee https://felix86.com/docs/devs/building-instructions/#important-files for more info" \
      12 78
    NEW_ROOTFS="$line"
else
    selected="${names[choice-1]}"
    selected_url=$(jq -r --arg n "$selected" '.[$n].url' <<< "$json")
    NEW_ROOTFS=$(whiptail --title "Installation path" --inputbox \
      "Installation path for $selected:" \
      10 60 "$INSTALLATION_DIR/rootfs" 3>&1 1>&2 2>&3) || exit 1
    NEW_ROOTFS=$(eval echo "$NEW_ROOTFS")
    NEW_ROOTFS=$(realpath "$NEW_ROOTFS")
    if [[ -z "$NEW_ROOTFS" || "$NEW_ROOTFS" == "/" ]]; then
        echo "Error: Rootfs is set to host root" >&2
        exit 1
    fi
    if [ ! -e "$NEW_ROOTFS" ] || [ -d "$NEW_ROOTFS" ] && [ -z "$(ls -A "$NEW_ROOTFS" 2> /dev/null)" ]; then
        check_url $selected_url
        echo "Installing rootfs to $NEW_ROOTFS"
        sudo mkdir -p "$NEW_ROOTFS"
        if ! sudo -u nobody sh -c "test -r '$NEW_ROOTFS'"; then
            if ! whiptail --title "Warning" --yesno \
              "Different users cannot access this rootfs path. This may lead to problems with programs that try to switch to a different user.\n\nIt is not recommended to install the rootfs in paths not accessible by all users, such as the home directory.\n\nAre you sure you want to install the rootfs at $NEW_ROOTFS?" \
              14 60; then
                exit 1
            fi
        fi
        echo "Downloading $selected..."
        curl -L --progress-bar $selected_url | sudo tar --same-owner -xzf - -C "$NEW_ROOTFS"
        sudo chown 0:0 "$NEW_ROOTFS"
        sudo mkdir "$NEW_ROOTFS/home"
        CURRENT_USER=$(whoami)
        echo "Creating home directory for $CURRENT_USER..."
        sudo mkdir "$NEW_ROOTFS/home/$CURRENT_USER"
        sudo chown $CURRENT_USER:$CURRENT_USER "$NEW_ROOTFS/home/$CURRENT_USER"
        sudo mkdir -p "$NEW_ROOTFS/dev"
        sudo mkdir -p "$NEW_ROOTFS/proc"
        sudo mkdir -p "$NEW_ROOTFS/sys"
        sudo mkdir -p "$NEW_ROOTFS/run"
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
        if ! set_rootfs "$NEW_ROOTFS"; then
            echo "Failed to set rootfs to $NEW_ROOTFS"
            if felix86_version_gte "26.08"; then
                echo "Please run: sudo felix86 --set-config general.rootfs_path=$NEW_ROOTFS"
            else
                echo "Please run: felix86 --set-rootfs $NEW_ROOTFS"
            fi
        fi
    else
        echo "$NEW_ROOTFS already exists and is not empty, I won't unpack the rootfs there"
        exit 1
    fi
fi