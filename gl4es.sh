#!/bin/bash
set -euo pipefail

arch=$(uname -m)

if [ "$(id -u)" -eq 0 ]; then
    echo "This script is not meant to be run as root." >&2
    echo "It will create a home directory inside the rootfs for your current user, and if that user is root, this might not be what you want." >&2
    read -p "Are you sure you want to continue as root? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

if [ "$arch" != "riscv64" ]; then
    echo "Error: You are not on 64-bit RISC-V. felix86 only works on 64-bit RISC-V." >&2
    exit 1
fi

for cmd in felix86 curl tar unzip sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd is not installed. Please install it and try again." >&2
        exit 1
    fi
done

INSTALLATION_DIR="/opt/felix86"

sudo mkdir -p "$INSTALLATION_DIR/gl4es/lib"
sudo curl -fsSL http://cdn.felix86.com/misc/gl4es/gl4es.zip -o "$INSTALLATION_DIR/gl4es/lib/gl4es.zip"
sudo unzip "$INSTALLATION_DIR/gl4es/lib/gl4es.zip" -d "$INSTALLATION_DIR/gl4es/lib"
sudo rm "$INSTALLATION_DIR/gl4es/lib/gl4es.zip"
sudo ln -sf libGL.so.1 "$INSTALLATION_DIR/gl4es/lib/libGLX.so.0"

TMP=$(mktemp)
cat > "$TMP" << 'EOF'
#!/bin/bash
set -euo pipefail
if ! command -v felix86 >/dev/null 2>&1; then
    echo "Error: felix86 is not installed. Please install it and try again." >&2
    exit 1
fi
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="$(felix86 -g)"
export FELIX86_HOST_ENVIRONMENT="LD_LIBRARY_PATH=$DIR/lib"
export FELIX86_ENABLED_THUNKS=glx
export FELIX86_QUIET=0
exec felix86 "$ROOTFS/bin/bash" -- "$@"
EOF
chmod +x "$TMP"
sudo mv "$TMP" "$INSTALLATION_DIR/gl4es/felix86-gl4es-wrapper.sh"
sudo ln -sf "$INSTALLATION_DIR/gl4es/felix86-gl4es-wrapper.sh" /usr/bin/felix86-gl4es