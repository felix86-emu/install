#!/bin/bash

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

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
    die "URL is invalid or unreachable: $url"
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
  sudo cp -rp "$src" "$dst" || die "failed to copy '$src' to '$dst'"
}

if [ "$(id -u)" -eq 0 ]; then
    if command -v whiptail >/dev/null 2>&1; then
        if ! whiptail --title "Warning" --yesno \
          "This script is not meant to be run as root.\n\nAre you sure you want to continue?" \
          0 0; then
            exit 1
        fi
    else
        echo "Warning: This script is not meant to be run as root."
        read -r -p "Are you sure you want to continue? [y/N] " reply
        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) ;;
            *) exit 1 ;;
        esac
    fi
fi

if [ "$arch" != "riscv64" ]; then
    die "You are not on 64-bit RISC-V. felix86 only works on 64-bit RISC-V."
fi

missing=()
for cmd in curl tar unzip sudo jq whiptail; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
    die "missing required tools: ${missing[*]}
  Ubuntu/Debian: sudo apt install ${missing[*]}
  Arch:          sudo pacman -S ${missing[*]}"
fi

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    die "\$HOME is not set or not a valid directory."
fi

if [ -z "$USER" ]; then
    die "\$USER is not set"
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
    NEW_ROOTFS=$(realpath "$NEW_ROOTFS")
    if [[ -z "$NEW_ROOTFS" || "$NEW_ROOTFS" == "/" ]]; then
        die "Rootfs is set to host root"
    fi
    if [ ! -e "$NEW_ROOTFS" ] || [ -d "$NEW_ROOTFS" ] && [ -z "$(ls -A "$NEW_ROOTFS" 2> /dev/null)" ]; then
        check_url $selected_url
        echo "Installing rootfs to $NEW_ROOTFS"
        sudo mkdir -p "$NEW_ROOTFS"
        if ! sudo -u nobody test -r "$NEW_ROOTFS"; then
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
        for f in mtab passwd passwd- group group- shadow shadow- gshadow gshadow- \
                 hosts hostname timezone localtime fstab subuid subgid machine-id resolv.conf sudoers; do
            copy_and_notify "/etc/$f" "$NEW_ROOTFS/etc/$f"
        done
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
        die "$NEW_ROOTFS already exists and is not empty, I won't unpack the rootfs there"
    fi
fi