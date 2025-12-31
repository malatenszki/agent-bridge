# Agent Bridge Daemon

A macOS daemon that allows you to control CLI agents (like Claude Code) remotely from your iOS device.

## Requirements

- macOS 13.0+
- tmux installed (`brew install tmux`)
- Swift 5.9+

## Installation

### Option 1: Install Script (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/malatenszki/agent-bridge-daemon/main/install.sh | bash
```

### Option 2: Build from Source

```bash
git clone https://github.com/malatenszki/agent-bridge-daemon.git
cd agent-bridge-daemon
swift build -c release
sudo cp .build/release/agent-bridge-daemon /usr/local/bin/
```

### Option 3: Homebrew

```bash
brew tap malatenszki/agent-bridge
brew install agent-bridge-daemon
```

## Usage

1. Start the daemon:
   ```bash
   agent-bridge-daemon
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
4. Opens Terminal.app so you can see sessions on Mac too

## Configuration

The daemon stores device keys in:
```
~/Library/Application Support/AgentBridge/device_keys.json
```

## Uninstall

```bash
sudo rm /usr/local/bin/agent-bridge-daemon
rm -rf ~/Library/Application\ Support/AgentBridge
```

## License

MIT
