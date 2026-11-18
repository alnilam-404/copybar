#!/bin/bash
# Compile CopyBar.swift et produit CopyBar.app à côté de ce script.
#
#   ./build.sh                 build local, signature ad hoc, purge l'autorisation Accessibilité
#   ./build.sh --keep-tcc      idem sans toucher aux autorisations
#   ./build.sh --universal     binaire Apple Silicon + Intel (pour une version publiée)
#
# Variables : COPYBAR_SIGN_IDENTITY="Developer ID Application" pour une vraie signature
# (runtime renforcé, horodatage : requis pour la notarisation, voir release.sh).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.1.0
BUNDLE_ID=io.github.alnilam-404.copybar
IDENTITY="${COPYBAR_SIGN_IDENTITY:--}"
KEEP_TCC=0; UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --keep-tcc) KEEP_TCC=1 ;;
        --universal) UNIVERSAL=1 ;;
        *) echo "option inconnue : $arg" >&2; exit 2 ;;
    esac
done

# Le bundle est assemblé et signé dans un dossier temporaire : dans un dossier synchronisé
# (iCloud…), il reçoit des attributs étendus que codesign refuse.
OUT="${COPYBAR_OUT:-$(pwd)}/CopyBar.app"      # COPYBAR_OUT : autre dossier de sortie
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/CopyBar.app"
mkdir -p "$APP/Contents/MacOS"

compile() {   # $1 = architecture, $2 = sortie
    swiftc -O -swift-version 5 -parse-as-library -target "$1-apple-macos13.0" CopyBar.swift -o "$2"
}
if [ "$UNIVERSAL" = 1 ]; then
    compile arm64 "$WORK/arm64"
    compile x86_64 "$WORK/x86_64"
    lipo -create "$WORK/arm64" "$WORK/x86_64" -output "$APP/Contents/MacOS/CopyBar"
else
    compile "$(uname -m)" "$APP/Contents/MacOS/CopyBar"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>CopyBar</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>CFBundleExecutable</key><string>CopyBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi

# Une signature ad hoc n'a pas d'identité stable : chaque build change le hash du binaire et
# l'ancienne autorisation Accessibilité ne correspond plus. On la purge pour que macOS
# redemande proprement au prochain lancement (au lieu d'une case cochée mais inopérante).
# ATTENTION : l'identifiant de bundle est le même pour l'app installée ailleurs (~/bin), qui
# perd donc aussi son autorisation. « ./build.sh --keep-tcc » compile sans y toucher.
# Avec une vraie identité de signature, l'autorisation survit aux mises à jour : rien à purger.
if [ "$IDENTITY" = "-" ] && [ "$KEEP_TCC" = 0 ]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
rm -rf "$OUT"
ditto "$APP" "$OUT"
echo "OK : $OUT ($VERSION)"
