#!/bin/zsh
set -euo pipefail
SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
SOURCE_APPLICATION="$PROJECT_DIRECTORY/dist/StorageScope.app"
TARGET_APPLICATION="/Applications/StorageScope.app"
BACKUP_DIRECTORY=""
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -d "$SOURCE_APPLICATION" && ! -L "$SOURCE_APPLICATION" ]] || { echo 'Build StorageScope.app first.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APPLICATION/Contents/Info.plist")" == com.labrioche.StorageScope ]]
/usr/bin/codesign --verify --deep --strict "$SOURCE_APPLICATION"
if /usr/bin/pgrep -x StorageScope >/dev/null; then echo 'Quit StorageScope before replacing it.' >&2; exit 1; fi
if [[ -e "$TARGET_APPLICATION" || -L "$TARGET_APPLICATION" ]]; then
    [[ -d "$TARGET_APPLICATION" && ! -L "$TARGET_APPLICATION" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APPLICATION/Contents/Info.plist")" == com.labrioche.StorageScope ]]
    BACKUP_DIRECTORY=$(/usr/bin/mktemp -d "/tmp/StorageScope-previous.XXXXXX")
    /bin/mv "$TARGET_APPLICATION" "$BACKUP_DIRECTORY/StorageScope.app"
fi
# Preserve signatures and extended attributes, including download quarantine.
if ! /usr/bin/ditto "$SOURCE_APPLICATION" "$TARGET_APPLICATION" || ! /usr/bin/codesign --verify --deep --strict "$TARGET_APPLICATION"; then
    if [[ -d "$TARGET_APPLICATION" && ! -L "$TARGET_APPLICATION" ]]; then
        FAILED_DIRECTORY=$(/usr/bin/mktemp -d "/tmp/StorageScope-failed.XXXXXX")
        /bin/mv "$TARGET_APPLICATION" "$FAILED_DIRECTORY/StorageScope.app"
    fi
    if [[ -n "$BACKUP_DIRECTORY" ]]; then /bin/mv "$BACKUP_DIRECTORY/StorageScope.app" "$TARGET_APPLICATION"; fi
    echo 'Installation failed; the previous application was preserved.' >&2; exit 1
fi
"$LAUNCH_SERVICES_REGISTER" -f "$TARGET_APPLICATION"
echo 'StorageScope is installed in /Applications. macOS may require individual approval in Privacy & Security.'
if [[ -n "$BACKUP_DIRECTORY" ]]; then echo "Previous application preserved in $BACKUP_DIRECTORY until you verify the replacement."; fi
