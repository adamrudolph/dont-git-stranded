#!/bin/zsh
# Builds build/DontGitStranded.app (release, ad-hoc signed). Usage: scripts/build-app.sh [--install]
#   --install  also copies it to ~/Applications and launches it
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/DontGitStranded"

APP="build/DontGitStranded.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DontGitStranded"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.adamrudolph.DontGitStranded</string>
    <key>CFBundleName</key><string>Don't Git Stranded</string>
    <key>CFBundleDisplayName</key><string>Don't Git Stranded</string>
    <key>CFBundleExecutable</key><string>DontGitStranded</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Adam Rudolph. MIT License.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x DontGitStranded 2>/dev/null || true
    rm -rf ~/Applications/"DontGitStranded.app"
    cp -R "$APP" ~/Applications/
    open ~/Applications/"DontGitStranded.app"
    echo "Installed to ~/Applications and launched"
fi
