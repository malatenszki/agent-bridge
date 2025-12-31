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
        echo "Install Xcode Command Line Tools: xcode-select --install"
    else
        echo "Install Swift from https://swift.org/download/"
        echo "Or use swiftly: curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash"
    fi
    exit 1
fi

# Check for C++ compiler (needed for BoringSSL) - Linux only
if [[ "$OS" == "Linux" ]]; then
    if ! command -v g++ &> /dev/null; then
        echo "C++ compiler (g++) is required but not installed."
        echo "Install it with: sudo apt install build-essential  (Debian/Ubuntu)"
        echo "            or: sudo dnf install gcc-c++           (Fedora)"
        echo "            or: sudo pacman -S base-devel          (Arch)"
        exit 1
    fi
fi

INSTALL_DIR="/usr/local/bin"
TEMP_DIR=$(mktemp -d)
REPO_URL="https://github.com/malatenszki/agent-bridge.git"

# Create install directory if it doesn't exist
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Creating $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
fi

cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "Cloning repository..."
git clone --depth 1 "$REPO_URL" "$TEMP_DIR" >/dev/null 2>&1 || {
    echo "Error: Failed to clone repository"
    exit 1
}

echo "Building (this may take a minute)..."
cd "$TEMP_DIR"

if swift build -c release --quiet 2>/dev/null; then
    echo "Installing..."
    sudo cp ".build/release/agent-bridge" "$INSTALL_DIR/"
    sudo chmod +x "$INSTALL_DIR/agent-bridge"
else
    echo "Build failed."

    if [[ "$OS" == "Darwin" ]]; then
        echo "Downloading pre-built binary..."
        BINARY_URL="https://github.com/malatenszki/agent-bridge/releases/latest/download/agent-bridge-macos-universal"

        curl -fsSL "$BINARY_URL" -o /tmp/agent-bridge || {
            echo "Error: Failed to download binary"
            exit 1
        }
        sudo cp /tmp/agent-bridge "$INSTALL_DIR/"
        sudo chmod +x "$INSTALL_DIR/agent-bridge"
        rm -f /tmp/agent-bridge
    else
        echo ""
        echo "Error: Build failed on Linux. Please ensure you have:"
        echo "  - Swift 5.9+ installed correctly"
        echo "  - build-essential (g++) installed"
        echo "Then try again."
        exit 1
    fi
fi

echo ""
echo "Installation complete!"
echo ""
echo "To start, run:"
echo "  agent-bridge"
echo ""
echo "Then scan the QR code with the Agent Bridge iOS app."
