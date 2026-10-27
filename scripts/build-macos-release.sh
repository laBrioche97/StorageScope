#!/bin/zsh
set -euo pipefail
TAG=${1:?Pass a stable vX.Y.Z tag}
MODE=${2:-production}
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo 'Invalid stable tag' >&2; exit 1; }
VERSION=${TAG#v}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)" == "$VERSION" ]]
: "${SPARKLE_PRIVATE_KEY:?Sparkle private key is required}"
export STORAGESCOPE_SPARKLE_PUBLIC_KEY=${STORAGESCOPE_SPARKLE_PUBLIC_KEY:-$(cat Packaging/sparkle-public-key.txt)}
case "$MODE" in
    development)
        export STORAGESCOPE_SIGNING_IDENTITY=-
        PACKAGE=StorageScope-macOS-universal-DEVELOPMENT.pkg
        ;;
    production)
        : "${STORAGESCOPE_SIGNING_IDENTITY:?Developer ID Application is required}"
        : "${STORAGESCOPE_INSTALLER_IDENTITY:?Developer ID Installer is required}"
        : "${APPLE_API_KEY_PATH:?Notarization credentials are required}"
        : "${APPLE_API_KEY_ID:?Notarization credentials are required}"
        : "${APPLE_API_ISSUER_ID:?Notarization credentials are required}"
        PACKAGE=StorageScope-macOS-universal.pkg
        ;;
    *) echo 'Explicit development or production mode required' >&2; exit 1 ;;
esac
export STORAGESCOPE_ARCHITECTURES=universal
./scripts/build-app.sh
mkdir -p release-assets
if [[ "$MODE" == production ]]; then
    ditto -c -k --sequesterRsrc --keepParent dist/StorageScope.app release-assets/StorageScope-universal.zip
    xcrun notarytool submit release-assets/StorageScope-universal.zip --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
    xcrun stapler staple dist/StorageScope.app
    xcrun stapler validate dist/StorageScope.app
    spctl --assess --type execute --verbose=2 dist/StorageScope.app
fi
ditto -c -k --sequesterRsrc --keepParent dist/StorageScope.app release-assets/StorageScope-universal.zip
pkgbuild --analyze --root dist/StorageScope.app dist/component.plist
# Bundle replacement stays at /Applications, never relocate another user copy.
python3 - <<'PY'
import plistlib
from pathlib import Path
p=Path('dist/component.plist')
data=plistlib.loads(p.read_bytes())
for component in data:
    component['BundleIsRelocatable']=False
    component['BundleOverwriteAction']='upgrade'
p.write_bytes(plistlib.dumps(data))
PY
pkgbuild --component dist/StorageScope.app --component-plist dist/component.plist --install-location /Applications --identifier com.labrioche.StorageScope --version "$VERSION" dist/StorageScope-component.pkg
productbuild --synthesize --package dist/StorageScope-component.pkg dist/distribution.xml
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as E
p=Path('dist/distribution.xml'); tree=E.parse(p); root=tree.getroot()
E.SubElement(root, 'allowed-os-versions').append(E.Element('os-version', {'min':'14.0'}))
options=root.find('options')
if options is None: options=E.SubElement(root,'options')
options.set('hostArchitectures','arm64,x86_64')
tree.write(p,encoding='utf-8',xml_declaration=True)
PY
if [[ "$MODE" == production ]]; then
    productbuild --distribution dist/distribution.xml --package-path dist --sign "$STORAGESCOPE_INSTALLER_IDENTITY" "release-assets/$PACKAGE"
    xcrun notarytool submit "release-assets/$PACKAGE" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
    xcrun stapler staple "release-assets/$PACKAGE"
    xcrun stapler validate "release-assets/$PACKAGE"
    pkgutil --check-signature "release-assets/$PACKAGE"
    spctl --assess --type install --verbose=2 "release-assets/$PACKAGE"
else
    productbuild --distribution dist/distribution.xml --package-path dist "release-assets/$PACKAGE"
fi
SPARKLE_SIGNER=$(find .build -type f -name sign_update -print -quit)
[[ -x "$SPARKLE_SIGNER" ]] || { echo 'Sparkle signing tool missing' >&2; exit 1; }
export SPARKLE_SIGNATURE=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGNER" --ed-key-file - release-assets/StorageScope-universal.zip)
export STORAGESCOPE_RELEASE_TAG="$TAG"
python3 scripts/create-appcast.py
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGNER" --ed-key-file - release-assets/appcast.xml
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGNER" --ed-key-file - --verify release-assets/appcast.xml
for ASSET in StorageScope-universal.zip "$PACKAGE"; do
    (cd release-assets && shasum -a 256 "$ASSET" > "$ASSET.sha256")
done
