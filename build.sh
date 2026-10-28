#!/bin/bash
# Baut PhotoHub.app – nur mit den Command Line Tools, ohne Xcode und ohne Entwicklerzertifikat.
#
#   ./build.sh            → build/PhotoHub.app
#   ./build.sh --install  → zusätzlich nach /Applications kopieren
#   ./build.sh --icon     → App-Icon neu zeichnen (Resources/AppIcon.icns)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PhotoHub.app"
mkdir -p build

FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos13.0")

# Manche Command-Line-Tools-Installationen enthalten eine veraltete module.modulemap, die mit
# bridging.modulemap kollidiert („redefinition of module 'SwiftBridging'“). Sie wird beim
# Kompilieren per VFS-Overlay ausgeblendet – am System selbst wird nichts verändert.
SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/clt-overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$SWIFT_INCLUDE", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
fi

if [[ "${1:-}" == "--icon" ]]; then
  swiftc "${FLAGS[@]}" -o build/make-icon scripts/make-icon.swift
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  echo "Icon aktualisiert: Resources/AppIcon.icns"
  exit 0
fi

echo "Kompiliere …"
swiftc "${FLAGS[@]}" -module-name PhotoHub -o build/PhotoHub Sources/PhotoHub/*.swift

echo "Erstelle $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/PhotoHub "$APP/Contents/MacOS/PhotoHub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc-Signatur („-“): braucht weder Zertifikat noch Apple-Account.
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/PhotoHub.app
  cp -R "$APP" /Applications/
  echo "Installiert: /Applications/PhotoHub.app"
fi

echo "Fertig: $APP"
