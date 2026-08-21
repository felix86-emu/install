#!/bin/bash

set -euo pipefail

INSTALLATION_DIR="/opt/felix86"
FELIX86="$(command -v felix86 || true)"

ROOTFS=""
if [ -n "$FELIX86" ]; then
    ROOTFS="$("$FELIX86" --get-config general.rootfs_path 2>/dev/null || true)"
fi

echo "Uninstalling felix86, requesting permission..."

if [ -n "$FELIX86" ]; then
    sudo "$FELIX86" -u >/dev/null 2>&1 || true
fi

sudo rm -f /etc/binfmt.d/felix86-* \
           /usr/lib/binfmt.d/felix86-* \
           /usr/local/lib/binfmt.d/felix86-* \
           /run/binfmt.d/felix86-*

if [ -d /run/systemd/system ]; then
    sudo systemctl daemon-reload || true
    sudo systemctl restart systemd-binfmt || true
fi

case "$ROOTFS" in
    /?*)
        if [ -d "$ROOTFS" ]; then
            ROOTFS_REAL="$(realpath -m "$ROOTFS" 2>/dev/null || echo "$ROOTFS")"
            INSTALLATION_DIR_REAL="$(realpath -m "$INSTALLATION_DIR" 2>/dev/null || echo "$INSTALLATION_DIR")"
            case "$ROOTFS_REAL" in
                "$INSTALLATION_DIR_REAL"|"$INSTALLATION_DIR_REAL"/*)
                    ;;
                *)
                    echo "$ROOTFS outside $INSTALLATION_DIR, not managed by this script, refusing to delete"
                    ;;
            esac
        fi
        ;;
esac

sudo rm -rf "$INSTALLATION_DIR"
sudo rm -rf /etc/opt/felix86
sudo rm -f /usr/local/bin/felix86

if [ -L /usr/bin/felix86 ]; then
    sudo rm -f /usr/bin/felix86
fi

sudo rm -f /usr/local/share/vulkan/implicit_layer.d/felix86-MangoHud.riscv64.json

rm -rf "$HOME/.config/felix86" || true
rm -f "$HOME/.felix86_history" || true

if command -v xdg-icon-resource >/dev/null 2>&1; then
    for size in 16 24 32 48 96 128; do
        xdg-icon-resource uninstall --mode user --context apps --size "$size" offtkp-felix86 >/dev/null 2>&1 || true
    done
fi

echo "felix86 successfully uninstalled"
