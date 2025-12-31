#!/bin/bash
set -e

echo "==================================="
echo "  Agent Bridge Installer"
echo "==================================="
echo ""

OS="$(uname)"

# Check for supported OS
if [[ "$OS" != "Darwin" && "$OS" != "Linux" ]]; then
    echo "Error: This tool only works on macOS and Linux"
    exit 1
fi

# Check for tmux
if ! command -v tmux &> /dev/null; then
    echo "tmux is required but not installed."
    if [[ "$OS" == "Darwin" ]]; then
        echo "Install it with: brew install tmux"
    else
        echo "Install it with: sudo apt install tmux  (Debian/Ubuntu)"
        echo "            or: sudo dnf install tmux  (Fedora)"
        echo "            or: sudo pacman -S tmux    (Arch)"
    fi
    exit 1
fi

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "Swift is required but not installed."
    if [[ "$OS" == "Darwin" ]]; then
        echo "Install Xcode or Xcode Command Line Tools"
    else
        echo "Install Swift from https://swift.org/download/"
        echo "Or use swiftly: curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash"
    fi
    exit 1
fi

INSTALL_DIR="/usr/local/bin"
TEMP_DIR=$(mktemp -d)
REPO_URL="https://github.com/malatenszki/agent-bridge.git"

echo "Cloning repository..."
git clone --depth 1 "$REPO_URL" "$TEMP_DIR" 2>/dev/null

echo "Building (this may take a minute)..."
cd "$TEMP_DIR"
swift build -c release --quiet

echo "Installing..."
sudo cp ".build/release/agent-bridge" "$INSTALL_DIR/"
sudo chmod +x "$INSTALL_DIR/agent-bridge"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "Installation complete!"
echo ""
echo "To start, run:"
echo "  agent-bridge"
echo ""
echo "Then scan the QR code with the Agent Bridge iOS app."
