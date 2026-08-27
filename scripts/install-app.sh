#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
SOURCE_APPLICATION="$PROJECT_DIRECTORY/dist/StorageScope.app"
TARGET_APPLICATION="/Applications/StorageScope.app"
SIGNING_IDENTITY=${STORAGESCOPE_SIGNING_IDENTITY:--}
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$SOURCE_APPLICATION" ]]; then
    echo "StorageScope.app est absent. Exécutez d’abord ./scripts/build-app.sh" >&2
    exit 1
fi

if [[ -e "$TARGET_APPLICATION" ]]; then
    BACKUP_DIRECTORY=$(/usr/bin/mktemp -d "/tmp/StorageScope-previous.XXXXXX")
    /bin/mv "$TARGET_APPLICATION" "$BACKUP_DIRECTORY/StorageScope.app"
    echo "Version précédente sauvegardée dans $BACKUP_DIRECTORY"
fi

/usr/bin/ditto --norsrc --noextattr "$SOURCE_APPLICATION" "$TARGET_APPLICATION"
/usr/bin/xattr -cr "$TARGET_APPLICATION"
/usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    "$TARGET_APPLICATION"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$TARGET_APPLICATION"
"$LAUNCH_SERVICES_REGISTER" -f "$TARGET_APPLICATION"

echo "StorageScope est installée dans /Applications."
