#!/bin/sh
# Builds "build/LaTeX Writer.app" so the app can be double-clicked or kept in the Dock.
set -e
cd "$(dirname "$0")"
swift build -c release
app="build/LaTeX Writer.app"
contents="$app/Contents"
binary="$PWD/$contents/MacOS/LatexWriter"

# Replacing the bundle under a running copy leaves a stale process that ignores Dock clicks and Quit.
# So a running copy is asked to quit first (it autosaves on quit) and is reopened once the new build is in place.
was_running=0
if pgrep -f "$binary" >/dev/null; then
    was_running=1
    osascript -e 'tell application id "local.latexwriter" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$binary" >/dev/null || break
        sleep 0.5
    done
    pkill -f "$binary" || true   # a copy left stale by an earlier rebuild does not answer Quit
fi

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp .build/release/LatexWriter "$contents/MacOS/"
cp -R Fonts "$contents/Resources/"   # macOS registers these for the app via ATSApplicationFontsPath
cp Resources/AppIcon.icns "$contents/Resources/"   # regenerate with scripts/make-icon.sh
cat > "$contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LaTeX Writer</string>
    <key>CFBundleIdentifier</key><string>local.latexwriter</string>
    <key>CFBundleExecutable</key><string>LatexWriter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF
echo "Built $app"
if [ "$was_running" = 1 ]; then open "$app"; echo "Reopened the app with the new build"; fi
