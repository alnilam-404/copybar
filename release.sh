#!/bin/bash
# Produit CopyBar-<version>.zip signé Developer ID et notarisé, prêt à joindre à une release GitHub.
#
# Prérequis, une seule fois :
#   1. Compte Apple Developer Program et certificat « Developer ID Application » dans le trousseau.
#   2. xcrun notarytool store-credentials copybar --apple-id <mail> --team-id <équipe> --password <mot de passe d'app>
# Usage :
#   ./release.sh
set -euo pipefail
cd "$(dirname "$0")"
# « Developer ID Application » suffit tant que le trousseau n'en contient qu'un.
export COPYBAR_SIGN_IDENTITY="${COPYBAR_SIGN_IDENTITY:-Developer ID Application}"

# Tout se passe dans un dossier temporaire : un dossier synchronisé (iCloud…) ajoute au bundle
# des attributs étendus qui invalident la signature.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
COPYBAR_OUT="$WORK" ./build.sh --universal
APP="$WORK/CopyBar.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$(pwd)/CopyBar-$VERSION.zip"

codesign --verify --strict --deep "$APP"
ditto -c -k --keepParent "$APP" "$WORK/envoi.zip"
xcrun notarytool submit "$WORK/envoi.zip" --keychain-profile "${COPYBAR_NOTARY_PROFILE:-copybar}" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"            # le zip publié contient l'app agrafée
echo "OK : $ZIP — à publier avec : gh release create v$VERSION \"$ZIP\""
