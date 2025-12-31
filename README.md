# Agent Bridge

A daemon that allows you to control CLI agents (like Claude Code) remotely from your iOS device. Works on **macOS** and **Linux**.

## Requirements

### macOS
- macOS 13.0+
- tmux (`brew install tmux`)
- Xcode Command Line Tools (`xcode-select --install`)

### Linux
- Ubuntu 20.04+ / Debian 11+ / Fedora 38+ / Arch
- tmux (`sudo apt install tmux` or equivalent)
- C++ compiler (`sudo apt install build-essential` or equivalent)
- Swift 5.9+ (install from [swift.org](https://swift.org/download/) or use [swiftly](https://github.com/swiftlang/swiftly))

## Installation

### Option 1: Install Script (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/malatenszki/agent-bridge/main/install.sh | bash
```

### Option 2: Build from Source

```bash
git clone https://github.com/malatenszki/agent-bridge.git
cd agent-bridge
swift build -c release
sudo cp .build/release/agent-bridge /usr/local/bin/
```

### Option 3: Homebrew (macOS only)

```bash
brew tap malatenszki/agent-bridge
brew install agent-bridge
```

## Usage

1. Start the daemon:
   ```bash
   agent-bridge
   ```

2. A QR code will appear in the terminal

3. Scan the QR code with the Agent Bridge iOS app

4. Start controlling your CLI agents from your phone!

## Features

- Start new Claude Code sessions from iOS
- Send input to running sessions
- View real-time output
- Yes/No quick responses
- Sessions run in tmux (visible on Mac too)

## How It Works

The daemon:
1. Runs a local web server (default port 8765)
2. Creates tmux sessions for each agent
3. Streams output via WebSocket
4. Sessions are visible in your terminal (attach with `tmux attach`)

## Configuration

The daemon stores device keys in:

**macOS:**
```
~/Library/Application Support/AgentBridge/device_keys.json
```

**Linux:**
```
~/.config/AgentBridge/device_keys.json
```

## Uninstall

**macOS:**
```bash
sudo rm /usr/local/bin/agent-bridge
rm -rf ~/Library/Application\ Support/AgentBridge
```

**Linux:**
```bash
sudo rm /usr/local/bin/agent-bridge
rm -rf ~/.config/AgentBridge
```

## License

MIT
