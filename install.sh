#!/bin/bash
set -e

# Default install location
INSTALL_DIR="${HOME}/.local/share/nudeploy"
BIN_DIR="${HOME}/.local/bin"

# Ensure directories exist
mkdir -p "$INSTALL_DIR"
mkdir -p "$BIN_DIR"

echo "Installing nudeploy to $INSTALL_DIR..."

# Check if running from source or curl
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SRC_DIR/nudeploy.nu" ] && [ -f "$SRC_DIR/lib.nu" ]; then
    # Local install
    cp "$SRC_DIR/nudeploy.nu" "$INSTALL_DIR/"
    cp "$SRC_DIR/lib.nu" "$INSTALL_DIR/"
else
    # Remote install
    echo "Downloading latest version from GitHub..."
    curl -fsSL "https://raw.githubusercontent.com/longcipher/nudeploy/main/nudeploy.nu" -o "$INSTALL_DIR/nudeploy.nu"
    curl -fsSL "https://raw.githubusercontent.com/longcipher/nudeploy/main/lib.nu" -o "$INSTALL_DIR/lib.nu"
fi

# Create shim
SHIM="$BIN_DIR/nudeploy"
echo "Creating shim at $SHIM..."

cat > "$SHIM" <<EOF
#!/bin/bash
exec nu "$INSTALL_DIR/nudeploy.nu" "\$@"
EOF

chmod +x "$SHIM"

# Check PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "Warning: $BIN_DIR is not in your PATH."
    echo "Add it to your PATH to run 'nudeploy' directly."
fi

echo "Done! Try running 'nudeploy --help'"
