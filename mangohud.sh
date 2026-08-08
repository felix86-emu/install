#!/bin/bash

set -euo pipefail

INSTALLATION_DIR="/opt/felix86"

arch=$(uname -m)

if [ "$arch" != "riscv64" ]; then
    echo "You are not on 64-bit RISC-V. felix86 only works on 64-bit RISC-V."
    exit 1
fi

for sub in "" /lib /bin /licenses; do
    if [ ! -d "$INSTALLATION_DIR$sub" ]; then
        echo "Install felix86 before running this script."
        break
    fi
done

missing=()
for cmd in curl tar sudo; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: missing required tools: ${missing[*]}"
    echo "  Ubuntu/Debian: sudo apt install ${missing[*]}"
    echo "  Arch:          sudo pacman -S ${missing[*]}"
    exit 1
fi

echo "Installing felix86 MangoHud fork, built from https://github.com/felix86-emu/MangoHud"
curl -fsSL -o /tmp/felix86_mangohud.tar.gz https://cdn.felix86.com/misc/mangohud/felix86-MangoHud.tar.gz
TMP_DIR="$(mktemp -d /tmp/felix86_mangohud.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
tar xf /tmp/felix86_mangohud.tar.gz -C "$TMP_DIR"
rm /tmp/felix86_mangohud.tar.gz

sudo mv "$TMP_DIR/lib/mangohud" "$INSTALLATION_DIR/lib/riscv64-linux-gnu"
sudo mv "$TMP_DIR/bin/mangohud" "$INSTALLATION_DIR/bin"
sudo mv "$TMP_DIR/MangoHud_LICENSE" "$INSTALLATION_DIR/licenses"

sudo mkdir -p /usr/local/share/vulkan/implicit_layer.d
sudo mv "$TMP_DIR/share/MangoHud.riscv64.json" "/usr/local/share/vulkan/implicit_layer.d/felix86-MangoHud.riscv64.json"
echo "felix86 MangoHud fork installed"