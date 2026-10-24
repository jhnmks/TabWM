#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TABWM_ROOT="$PWD"
TABWM_BUILD="$TABWM_ROOT/.build/manual"
TABWM_APP="$TABWM_ROOT/dist/TabWM.app"
TABWM_SDK="$(xcrun --show-sdk-path)"
# CLT's macOS 27 SDK references a SwiftUI macro plugin not shipped with CLT.
# Select the installed stable SDK when available; no downloads or toolchain edits.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  TABWM_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
TABWM_ARCH="$(uname -m)"
mkdir -p "$TABWM_BUILD" "$TABWM_ROOT/.build/module-cache" "$TABWM_APP/Contents/MacOS" "$TABWM_APP/Contents/Frameworks"
rm -rf "$TABWM_APP/Contents/Resources"
xcrun swiftc -sdk "$TABWM_SDK" -module-cache-path "$TABWM_ROOT/.build/module-cache" \
  -emit-library -emit-module -module-name TabWMCore -enable-testing -target "$TABWM_ARCH-apple-macosx15.0" \
  Sources/TabWMCore/*.swift -emit-module-path "$TABWM_BUILD/TabWMCore.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libTabWMCore.dylib' -o "$TABWM_BUILD/libTabWMCore.dylib"
xcrun swiftc -sdk "$TABWM_SDK" -module-cache-path "$TABWM_ROOT/.build/module-cache" \
  -parse-as-library -target "$TABWM_ARCH-apple-macosx15.0" -I "$TABWM_BUILD" -L "$TABWM_BUILD" -lTabWMCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' Sources/TabWM/*.swift -o "$TABWM_BUILD/TabWM"
cp "$TABWM_BUILD/TabWM" "$TABWM_APP/Contents/MacOS/TabWM"
cp "$TABWM_BUILD/libTabWMCore.dylib" "$TABWM_APP/Contents/Frameworks/libTabWMCore.dylib"
# App icon, drawn from the menu bar symbol. Regenerated only when the drawing script changes.
TABWM_ICON="$TABWM_BUILD/TabWM.icns"
if [[ ! -f "$TABWM_ICON" || scripts/make-icon.swift -nt "$TABWM_ICON" ]]; then
  rm -rf "$TABWM_BUILD/TabWM.iconset"
  xcrun swift -sdk "$TABWM_SDK" -module-cache-path "$TABWM_ROOT/.build/module-cache" scripts/make-icon.swift "$TABWM_BUILD/TabWM.iconset"
  iconutil -c icns "$TABWM_BUILD/TabWM.iconset" -o "$TABWM_ICON"
fi
mkdir -p "$TABWM_APP/Contents/Resources"
cp "$TABWM_ICON" "$TABWM_APP/Contents/Resources/TabWM.icns"
cat > "$TABWM_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TabWM</string>
<key>CFBundleIconFile</key><string>TabWM</string>
<key>CFBundleIdentifier</key><string>dev.tabwm.TabWM</string>
<key>CFBundleName</key><string>TabWM</string>
<key>CFBundleDisplayName</key><string>TabWM</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A stable identity keeps macOS privacy grants (Accessibility, Input Monitoring) valid across
# rebuilds. Ad-hoc signatures change every build, which silently revokes those grants.
# Create the identity once with ./scripts/create-signing-identity.sh.
TABWM_SIGN=-
if security find-identity -p codesigning 2>/dev/null | grep -q '"TabWM Local Signing"'; then
  # Fail fast instead of hanging if codesign would wait on a keychain prompt nobody sees.
  probe="$TABWM_BUILD/sign-probe"; cp /usr/bin/true "$probe"
  codesign --force --sign "TabWM Local Signing" "$probe" >/dev/null 2>&1 & probe_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$probe_pid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$probe_pid" 2>/dev/null; then
    kill "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null || true
    echo "note: codesign is waiting for keychain access. Run ./scripts/create-signing-identity.sh once in Terminal to allow it. Signing ad-hoc for now." >&2
  elif wait "$probe_pid"; then
    TABWM_SIGN="TabWM Local Signing"
  fi
  rm -f "$probe"
else
  echo "note: signing ad-hoc; macOS permissions reset on every build. Run ./scripts/create-signing-identity.sh once to fix that." >&2
fi
codesign --force --sign "$TABWM_SIGN" "$TABWM_APP/Contents/Frameworks/libTabWMCore.dylib"
# Pin the designated requirement to the identifier and certificate name, so it stays the
# same across rebuilds even though the code hash changes.
if [[ "$TABWM_SIGN" == "-" ]]; then
  codesign --force --sign - --identifier dev.tabwm.TabWM "$TABWM_APP"
else
  codesign --force --sign "$TABWM_SIGN" --identifier dev.tabwm.TabWM \
    --requirements '=designated => identifier "dev.tabwm.TabWM" and certificate leaf[subject.CN] = "TabWM Local Signing"' "$TABWM_APP"
fi
codesign --verify --deep --strict "$TABWM_APP"
python3 - "$TABWM_APP" <<'PY'
import sys
print('Built ' + sys.argv[1])
PY
