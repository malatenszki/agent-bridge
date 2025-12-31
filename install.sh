#!/bin/bash
set -e

echo "==================================="
echo "  Agent Bridge Daemon Installer"
echo "==================================="
echo ""

# Check for macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This tool only works on macOS"
    exit 1
fi

# Check for tmux
if ! command -v tmux &> /dev/null; then
    echo "tmux is required but not installed."
    echo "Install it with: brew install tmux"
    exit 1
fi

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "Swift is required but not installed."
    echo "Install Xcode or Xcode Command Line Tools"
    exit 1
fi

INSTALL_DIR="/usr/local/bin"
TEMP_DIR=$(mktemp -d)
REPO_URL="https://github.com/malatenszki/agent-bridge-daemon.git"

echo "Cloning repository..."
git clone --depth 1 "$REPO_URL" "$TEMP_DIR" 2>/dev/null

echo "Building (this may take a minute)..."
cd "$TEMP_DIR"
swift build -c release --quiet

echo "Installing..."
sudo cp ".build/release/agent-bridge-daemon" "$INSTALL_DIR/"
sudo chmod +x "$INSTALL_DIR/agent-bridge-daemon"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "Installation complete!"
echo ""
echo "To start the daemon, run:"
echo "  agent-bridge-daemon"
echo ""
echo "Then scan the QR code with the Agent Bridge iOS app."
