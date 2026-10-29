#!/bin/zsh
# Builds a release PerfMonitor.app next to the package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PerfMonitor
APP=PerfMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PerfMonitor "$APP/Contents/MacOS/PerfMonitor"
# Same binary acts as the CLI / MCP server when invoked as "perfmon".
ln -s PerfMonitor "$APP/Contents/MacOS/perfmon"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PerfMonitor</string>
  <key>CFBundleDisplayName</key><string>性能监控</string>
  <key>CFBundleIdentifier</key><string>local.perfmonitor</string>
  <key>CFBundleExecutable</key><string>PerfMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.7.2</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
scripts/signing.sh "$APP"
echo "Built $(pwd)/$APP"
