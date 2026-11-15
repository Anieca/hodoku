#!/bin/zsh
# Hodoku.app を作る。  scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Hodoku.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Hodoku "$APP/Contents/MacOS/Hodoku"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.anieca.hodoku</string>
    <key>CFBundleName</key><string>Hodoku</string>
    <key>CFBundleExecutable</key><string>Hodoku</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# 署名。アドホック署名だとビルドのたびにアプリが別物とみなされ、画面収録の許可を取り直すことになる。
# ログインキーチェーンに "Hodoku Local Signing" があればそれを使う（scripts/make-signing-cert.sh で作れる）。
IDENTITY="${HODOKU_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    if security find-certificate -c "Hodoku Local Signing" >/dev/null 2>&1; then
        IDENTITY="Hodoku Local Signing"
    else
        IDENTITY="-"
    fi
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "signed with: $IDENTITY"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Hodoku 2>/dev/null || true
    rm -rf "/Applications/Hodoku.app"
    cp -R "$APP" "/Applications/Hodoku.app"
    echo "installed: /Applications/Hodoku.app"
else
    echo "built: $APP"
fi
