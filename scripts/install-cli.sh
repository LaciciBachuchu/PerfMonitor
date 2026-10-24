#!/bin/zsh
# Links `perfmon` into ~/.local/bin (must be on PATH).
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)/PerfMonitor.app"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/perfmon" "$HOME/.local/bin/perfmon"
echo "Installed: $HOME/.local/bin/perfmon -> $APP/Contents/MacOS/perfmon"
