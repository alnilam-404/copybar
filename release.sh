#!/bin/bash
# Produit CopyBar-<version>.zip signé Developer ID et notarisé, prêt à joindre à une release GitHub.
# JAMAIS EXÉCUTÉ À CE JOUR (18/11/2026) : écrit d'après la documentation, à valider au premier usage.
#
# Prérequis, une seule fois :
#   1. Compte Apple Developer Program et certificat « Developer ID Application » dans le trousseau.
#   2. xcrun notarytool store-credentials copybar --apple-id <mail> --team-id <équipe> --password <mot de passe d'app>
# Usage :
#   COPYBAR_SIGN_IDENTITY="Developer ID Application: Nom (ÉQUIPE)" ./release.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${COPYBAR_SIGN_IDENTITY:?définir COPYBAR_SIGN_IDENTITY (certificat Developer ID Application)}"

./build.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" CopyBar.app/Contents/Info.plist)
ZIP="CopyBar-$VERSION.zip"

ditto -c -k --keepParent CopyBar.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "${COPYBAR_NOTARY_PROFILE:-copybar}" --wait
xcrun stapler staple CopyBar.app
ditto -c -k --keepParent CopyBar.app "$ZIP"      # le zip publié contient l'app agrafée
spctl --assess --type execute --verbose CopyBar.app
echo "OK : $ZIP — à publier avec : gh release create v$VERSION $ZIP"
