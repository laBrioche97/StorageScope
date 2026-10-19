#!/bin/zsh
set -euo pipefail
TAG=${1:?Pass a stable vX.Y.Z tag}
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo 'Invalid stable tag' >&2; exit 1; }
VERSION=${TAG#v}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)" == "$VERSION" ]]
: "${STORAGESCOPE_SIGNING_IDENTITY:?Developer ID Application is required}"
: "${STORAGESCOPE_INSTALLER_IDENTITY:?Developer ID Installer is required}"
: "${STORAGESCOPE_SPARKLE_PUBLIC_KEY:?Sparkle public key is required}"
: "${SPARKLE_PRIVATE_KEY:?Sparkle private key is required}"
: "${APPLE_API_KEY_PATH:?Notarization credentials are required}"
: "${APPLE_API_KEY_ID:?Notarization credentials are required}"
: "${APPLE_API_ISSUER_ID:?Notarization credentials are required}"
export STORAGESCOPE_ARCHITECTURES=universal
./scripts/build-app.sh
mkdir -p release-assets
ditto -c -k --sequesterRsrc --keepParent dist/StorageScope.app release-assets/StorageScope-universal.zip
xcrun notarytool submit release-assets/StorageScope-universal.zip --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
xcrun stapler staple dist/StorageScope.app
xcrun stapler validate dist/StorageScope.app
spctl --assess --type execute --verbose=2 dist/StorageScope.app
ditto -c -k --sequesterRsrc --keepParent dist/StorageScope.app release-assets/StorageScope-universal.zip

pkgbuild --component dist/StorageScope.app --install-location /Applications --identifier com.labrioche.StorageScope --version "$VERSION" dist/StorageScope-component.pkg
productbuild --package dist/StorageScope-component.pkg --sign "$STORAGESCOPE_INSTALLER_IDENTITY" release-assets/StorageScope-macOS-universal.pkg
xcrun notarytool submit release-assets/StorageScope-macOS-universal.pkg --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
xcrun stapler staple release-assets/StorageScope-macOS-universal.pkg
xcrun stapler validate release-assets/StorageScope-macOS-universal.pkg
pkgutil --check-signature release-assets/StorageScope-macOS-universal.pkg
spctl --assess --type install --verbose=2 release-assets/StorageScope-macOS-universal.pkg

SPARKLE_SIGNER=$(find .build -type f -name sign_update -print -quit)
if [[ -z "$SPARKLE_SIGNER" ]]; then echo 'Sparkle signing tool missing' >&2; exit 1; fi
export SPARKLE_SIGNATURE=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGNER" --ed-key-file - release-assets/StorageScope-universal.zip)
export STORAGESCOPE_RELEASE_TAG="$TAG"
python3 scripts/create-appcast.py
for ASSET in StorageScope-universal.zip StorageScope-macOS-universal.pkg; do
    (cd release-assets && shasum -a 256 "$ASSET" > "$ASSET.sha256")
done
